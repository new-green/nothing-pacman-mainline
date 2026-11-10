// SPDX-License-Identifier: GPL-2.0-only
/*
 * DRM driver for the display pipeline the bootloader (LK) leaves running on the
 * Nothing Phone (2a) (MediaTek MT6886, DSI command-mode panel).
 *
 * LK scans out a framebuffer in RAM through an OVL layer, DSI0 and a display
 * mutex. As in pacman-cmdfb (the fbdev predecessor), this driver only keeps that
 * pipeline fed: it copies damaged areas into LK's framebuffer with the drm_sysfb
 * helpers, cleans them to the point of coherency and starts a frame (mutex EN,
 * DSI_START). On top of the fbdev driver it gives userspace KMS, which Wayland
 * compositors need. Like pacman-cmdfb it
 *  - turns off OVL layers LK left on that do not show our framebuffer (the
 *    unlocked-bootloader warning) and makes ours opaque (LK leaves per-pixel
 *    alpha on; X and most compositors write alpha 0),
 *  - can leave rows under the rounded corners / camera hole out of the mode
 *    (top_margin/bottom_margin), and
 *  - switches our OVL layer off while the CRTC is disabled (DPMS, blanking).
 *
 * Device tree: the "nothing,pacman-cmdfb" node: reg = DSI0, display mutex,
 * framebuffer; properties width, height, stride. Only one of pacman-cmdfb and
 * this driver may be built.
 */

#include <linux/io.h>
#include <linux/mm.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_address.h>
#include <linux/platform_device.h>
#include <linux/spinlock.h>
#include <linux/workqueue.h>

#include <asm/cacheflush.h>

#include <drm/clients/drm_client_setup.h>
#include <drm/drm_atomic.h>
#include <drm/drm_atomic_state_helper.h>
#include <drm/drm_connector.h>
#include <drm/drm_damage_helper.h>
#include <drm/drm_device.h>
#include <drm/drm_drv.h>
#include <drm/drm_fbdev_shmem.h>
#include <drm/drm_fourcc.h>
#include <drm/drm_framebuffer.h>
#include <drm/drm_gem_atomic_helper.h>
#include <drm/drm_gem_framebuffer_helper.h>
#include <drm/drm_gem_shmem_helper.h>
#include <drm/drm_managed.h>
#include <drm/drm_modeset_helper.h>
#include <drm/drm_modeset_helper_vtables.h>
#include <drm/drm_print.h>
#include <drm/drm_probe_helper.h>

#include "drm_sysfb_helper.h"

#define DRIVER_NAME	"pacman-drm"
#define DRIVER_DESC	"Nothing Phone (2a) bootloader display pipeline"
#define DRIVER_MAJOR	1
#define DRIVER_MINOR	0

/* DSI0 */
#define DSI_START		0x00
/* display mutex */
#define MUTEX_EN(n)		(0x20 + 0x20 * (n))
#define MUTEX_MOD0(n)		(0x30 + 0x20 * (n))
#define MUTEX_MAX		16
/* MT6886 OVL (MediaTek's mtk_disp_ovl.c) */
#define OVL_SRC_CON		0x002c	/* bits 0-3: layer L0-L3 enable */
#define OVL_L_CON(n)		(0x0030 + 0x20 * (n))
#define OVL_CON_AEN		BIT(8)	/* alpha blending */
#define OVL_DATAPATH_EXT_CON	0x0324	/* bits 0-2: extended layer EL0-EL2 enable */
#define OVL_L_ADDR(n)		(0x0f40 + 0x20 * (n))
#define OVL_EL_ADDR(n)		(0x0fb0 + 0x10 * (n))
#define OVL_NUM_LAYERS		4
#define OVL_NUM_EXT_LAYERS	3

#define KICK_MIN_MS		16	/* at most ~60 frames per second */

static unsigned int top_margin;
module_param(top_margin, uint, 0444);
MODULE_PARM_DESC(top_margin, "Panel rows left out at the top (rounded up to a page start)");

static unsigned int bottom_margin;
module_param(bottom_margin, uint, 0444);
MODULE_PARM_DESC(bottom_margin, "Panel rows left out at the bottom");

struct pacman_drm {
	struct drm_sysfb_device sysfb;

	/* modesetting */
	u32 formats[DRM_SYSFB_PLANE_NFORMATS(1)];
	struct drm_plane primary_plane;
	struct drm_crtc crtc;
	struct drm_encoder encoder;
	struct drm_connector connector;

	/* display pipeline left running by LK */
	void __iomem *dsi;
	void __iomem *mutex;
	int mutex_id;
	void __iomem *fb_ovl;		/* OVL block whose layer shows our framebuffer */
	unsigned int fb_ovl_bit;	/* its SRC_CON enable bit */
	phys_addr_t paddr;
	void *vaddr;			/* whole panel, write-back mapping */
	unsigned int stride;
	unsigned int first_row;		/* first panel row of the mode */

	/* frame kicks: rows (mode coordinates) written since the last kick */
	struct delayed_work kick_work;
	spinlock_t dirty_lock;
	int dirty_y1, dirty_y2;		/* empty when y1 >= y2 */
};

static struct pacman_drm *to_pacman_drm(struct drm_device *dev)
{
	return container_of(to_drm_sysfb_device(dev), struct pacman_drm, sysfb);
}

/*
 * Frame kicks
 */

static void pacman_drm_kick(struct pacman_drm *p)
{
	unsigned long flags;
	int y1, y2;

	spin_lock_irqsave(&p->dirty_lock, flags);
	y1 = p->dirty_y1;
	y2 = p->dirty_y2;
	p->dirty_y1 = INT_MAX;
	p->dirty_y2 = 0;
	spin_unlock_irqrestore(&p->dirty_lock, flags);

	if (y1 < y2) {
		unsigned long start = (unsigned long)p->vaddr +
				      (size_t)(p->first_row + y1) * p->stride;

		/* make what the CPU wrote visible to the display engine */
		dcache_clean_poc(start, start + (size_t)(y2 - y1) * p->stride);
	}

	if (p->mutex_id >= 0)
		writel(1, p->mutex + MUTEX_EN(p->mutex_id));
	writel(0, p->dsi + DSI_START);
	writel(1, p->dsi + DSI_START);
}

static void pacman_drm_kick_work(struct work_struct *w)
{
	struct pacman_drm *p = container_of(to_delayed_work(w), struct pacman_drm, kick_work);

	pacman_drm_kick(p);
}

static void pacman_drm_mark_dirty(struct pacman_drm *p, int y1, int y2)
{
	unsigned long flags;

	spin_lock_irqsave(&p->dirty_lock, flags);
	p->dirty_y1 = min(p->dirty_y1, y1);
	p->dirty_y2 = max(p->dirty_y2, y2);
	spin_unlock_irqrestore(&p->dirty_lock, flags);

	/* no-op while a kick is pending: updates in between are coalesced */
	schedule_delayed_work(&p->kick_work, msecs_to_jiffies(KICK_MIN_MS));
}

/*
 * Modesetting
 */

static const u64 pacman_drm_primary_plane_format_modifiers[] = {
	DRM_SYSFB_PLANE_FORMAT_MODIFIERS,
};

static void pacman_drm_primary_plane_helper_atomic_update(struct drm_plane *plane,
							  struct drm_atomic_commit *state)
{
	struct pacman_drm *p = to_pacman_drm(plane->dev);
	struct drm_plane_state *new_state = drm_atomic_get_new_plane_state(state, plane);
	struct drm_plane_state *old_state = drm_atomic_get_old_plane_state(state, plane);
	struct drm_rect damage;

	drm_sysfb_plane_helper_atomic_update(plane, state);

	if (drm_atomic_helper_damage_merged(old_state, new_state, &damage))
		pacman_drm_mark_dirty(p, damage.y1, damage.y2);
}

static void pacman_drm_primary_plane_helper_atomic_disable(struct drm_plane *plane,
							   struct drm_atomic_commit *state)
{
	struct pacman_drm *p = to_pacman_drm(plane->dev);

	drm_sysfb_plane_helper_atomic_disable(plane, state);	/* clears to black */
	pacman_drm_mark_dirty(p, 0, p->sysfb.fb_mode.vdisplay);
}

/* DRM_SYSFB_PLANE_HELPER_FUNCS with our update/disable (they kick the panel) */
static const struct drm_plane_helper_funcs pacman_drm_primary_plane_helper_funcs = {
	.begin_fb_access = drm_sysfb_plane_helper_begin_fb_access,
	.end_fb_access = drm_gem_end_shadow_fb_access,
	.atomic_check = drm_sysfb_plane_helper_atomic_check,
	.atomic_update = pacman_drm_primary_plane_helper_atomic_update,
	.atomic_disable = pacman_drm_primary_plane_helper_atomic_disable,
	.get_scanout_buffer = drm_sysfb_plane_helper_get_scanout_buffer,
};

static const struct drm_plane_funcs pacman_drm_primary_plane_funcs = {
	DRM_SYSFB_PLANE_FUNCS,
	.destroy = drm_plane_cleanup,
};

static void pacman_drm_set_layer(struct pacman_drm *p, bool on)
{
	u32 val;

	if (!p->fb_ovl)
		return;
	val = readl(p->fb_ovl + OVL_SRC_CON);
	val = on ? val | p->fb_ovl_bit : val & ~p->fb_ovl_bit;
	writel(val, p->fb_ovl + OVL_SRC_CON);
	pacman_drm_mark_dirty(p, 0, 0);
}

static void pacman_drm_crtc_helper_atomic_enable(struct drm_crtc *crtc,
						 struct drm_atomic_commit *state)
{
	pacman_drm_set_layer(to_pacman_drm(crtc->dev), true);
}

static void pacman_drm_crtc_helper_atomic_disable(struct drm_crtc *crtc,
						  struct drm_atomic_commit *state)
{
	/* the OLED shows the black background: its pixels are off */
	pacman_drm_set_layer(to_pacman_drm(crtc->dev), false);
}

static const struct drm_crtc_helper_funcs pacman_drm_crtc_helper_funcs = {
	DRM_SYSFB_CRTC_HELPER_FUNCS,
	.atomic_enable = pacman_drm_crtc_helper_atomic_enable,
	.atomic_disable = pacman_drm_crtc_helper_atomic_disable,
};

static const struct drm_crtc_funcs pacman_drm_crtc_funcs = {
	DRM_SYSFB_CRTC_FUNCS,
	.destroy = drm_crtc_cleanup,
};

static const struct drm_encoder_funcs pacman_drm_encoder_funcs = {
	.destroy = drm_encoder_cleanup,
};

static const struct drm_connector_helper_funcs pacman_drm_connector_helper_funcs = {
	DRM_SYSFB_CONNECTOR_HELPER_FUNCS,
};

static const struct drm_connector_funcs pacman_drm_connector_funcs = {
	DRM_SYSFB_CONNECTOR_FUNCS,
	.destroy = drm_connector_cleanup,
};

static const struct drm_mode_config_funcs pacman_drm_mode_config_funcs = {
	DRM_SYSFB_MODE_CONFIG_FUNCS,
};

static int pacman_drm_mode_config_init(struct pacman_drm *p)
{
	struct drm_sysfb_device *sysfb = &p->sysfb;
	struct drm_device *dev = &sysfb->dev;
	const struct drm_format_info *format = sysfb->fb_format;
	unsigned int width = sysfb->fb_mode.hdisplay;
	unsigned int height = sysfb->fb_mode.vdisplay;
	size_t nformats;
	int ret;

	ret = drmm_mode_config_init(dev);
	if (ret)
		return ret;

	dev->mode_config.min_width = width;
	dev->mode_config.max_width = max_t(unsigned int, width, DRM_SHADOW_PLANE_MAX_WIDTH);
	dev->mode_config.min_height = height;
	dev->mode_config.max_height = max_t(unsigned int, height, DRM_SHADOW_PLANE_MAX_HEIGHT);
	dev->mode_config.funcs = &pacman_drm_mode_config_funcs;
	dev->mode_config.preferred_depth = format->depth;

	nformats = drm_sysfb_build_fourcc_list(dev, &format->format, 1,
					       p->formats, ARRAY_SIZE(p->formats));
	ret = drm_universal_plane_init(dev, &p->primary_plane, 0,
				       &pacman_drm_primary_plane_funcs,
				       p->formats, nformats,
				       pacman_drm_primary_plane_format_modifiers,
				       DRM_PLANE_TYPE_PRIMARY, NULL);
	if (ret)
		return ret;
	drm_plane_helper_add(&p->primary_plane, &pacman_drm_primary_plane_helper_funcs);
	drm_plane_enable_fb_damage_clips(&p->primary_plane);

	ret = drm_crtc_init_with_planes(dev, &p->crtc, &p->primary_plane, NULL,
					&pacman_drm_crtc_funcs, NULL);
	if (ret)
		return ret;
	drm_crtc_helper_add(&p->crtc, &pacman_drm_crtc_helper_funcs);

	ret = drm_encoder_init(dev, &p->encoder, &pacman_drm_encoder_funcs,
			       DRM_MODE_ENCODER_DSI, NULL);
	if (ret)
		return ret;
	p->encoder.possible_crtcs = drm_crtc_mask(&p->crtc);

	ret = drm_connector_init(dev, &p->connector, &pacman_drm_connector_funcs,
				 DRM_MODE_CONNECTOR_DSI);
	if (ret)
		return ret;
	drm_connector_helper_add(&p->connector, &pacman_drm_connector_helper_funcs);

	return drm_connector_attach_encoder(&p->connector, &p->encoder);
}

/*
 * Display pipeline left by LK
 */

static void pacman_drm_find_mutex(struct pacman_drm *p)
{
	int i;

	p->mutex_id = -1;
	for (i = 0; i < MUTEX_MAX && p->mutex_id < 0; i++)
		if (readl(p->mutex + MUTEX_MOD0(i)))
			p->mutex_id = i;
}

/*
 * One enable register of one OVL block: remember and make opaque the layer that
 * scans out our framebuffer, switch off all other enabled layers.
 */
static void pacman_drm_scan_layers(struct pacman_drm *p, struct device_node *np,
				   void __iomem *ovl, unsigned int reg, int count,
				   unsigned int (*addr)(int), const char *kind)
{
	struct drm_device *dev = &p->sysfb.dev;
	u32 fb = lower_32_bits(p->paddr);
	u32 enable = readl(ovl + reg), new = enable;
	int n;

	for (n = 0; n < count; n++) {
		u32 a = readl(ovl + addr(n));

		if (!(enable & BIT(n)))
			continue;
		if (a != fb) {
			new &= ~BIT(n);
			drm_info(dev, "%pOF: hiding LK layer %s%d (buffer %08x)\n", np, kind, n, a);
			continue;
		}
		if (p->fb_ovl || reg != OVL_SRC_CON) {
			drm_warn(dev, "%pOF: framebuffer also in %s%d: not handled\n", np, kind, n);
			continue;
		}
		p->fb_ovl = ovl;
		p->fb_ovl_bit = BIT(n);
		writel(readl(ovl + OVL_L_CON(n)) & ~OVL_CON_AEN, ovl + OVL_L_CON(n));
		drm_info(dev, "%pOF: framebuffer is layer L%d (made opaque)\n", np, n);
	}
	if (new != enable)
		writel(new, ovl + reg);
}

static unsigned int ovl_l_addr(int n)  { return OVL_L_ADDR(n); }
static unsigned int ovl_el_addr(int n) { return OVL_EL_ADDR(n); }

static void pacman_drm_scan_ovls(struct pacman_drm *p)
{
	struct device_node *np;

	for_each_compatible_node(np, NULL, "mediatek,mt6886-disp-ovl") {
		void __iomem *ovl = of_iomap(np, 0);

		if (!ovl)
			continue;
		pacman_drm_scan_layers(p, np, ovl, OVL_SRC_CON, OVL_NUM_LAYERS, ovl_l_addr, "L");
		pacman_drm_scan_layers(p, np, ovl, OVL_DATAPATH_EXT_CON, OVL_NUM_EXT_LAYERS,
				       ovl_el_addr, "EL");
		if (p->fb_ovl != ovl)
			iounmap(ovl);
	}
	if (!p->fb_ovl)
		drm_warn(&p->sysfb.dev, "no OVL layer shows the framebuffer: no blanking\n");
}

/*
 * DRM driver
 */

DEFINE_DRM_GEM_FOPS(pacman_drm_fops);

static const struct drm_driver pacman_drm_driver = {
	DRM_GEM_SHMEM_DRIVER_OPS,
	DRM_FBDEV_SHMEM_DRIVER_OPS,
	.name			= DRIVER_NAME,
	.desc			= DRIVER_DESC,
	.major			= DRIVER_MAJOR,
	.minor			= DRIVER_MINOR,
	.driver_features	= DRIVER_ATOMIC | DRIVER_GEM | DRIVER_MODESET,
	.fops			= &pacman_drm_fops,
};

static void pacman_drm_cancel_kicks(void *data)
{
	struct pacman_drm *p = data;

	cancel_delayed_work_sync(&p->kick_work);
}

static int pacman_drm_probe(struct platform_device *pdev)
{
	struct device *d = &pdev->dev;
	struct device_node *np = d->of_node;
	struct drm_sysfb_device *sysfb;
	struct drm_device *dev;
	struct pacman_drm *p;
	struct resource *res;
	u32 width, height, stride;
	unsigned int rows;
	int ret;

	p = devm_drm_dev_alloc(d, &pacman_drm_driver, struct pacman_drm, sysfb.dev);
	if (IS_ERR(p))
		return PTR_ERR(p);
	sysfb = &p->sysfb;
	dev = &sysfb->dev;
	platform_set_drvdata(pdev, p);

	if (of_property_read_u32(np, "width", &width) ||
	    of_property_read_u32(np, "height", &height) ||
	    of_property_read_u32(np, "stride", &stride))
		return dev_err_probe(d, -EINVAL, "width/height/stride missing\n");

	/* regs: 0 = DSI0, 1 = display mutex, 2 = framebuffer (RAM reserved by LK) */
	p->dsi = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(p->dsi))
		return PTR_ERR(p->dsi);
	p->mutex = devm_platform_ioremap_resource(pdev, 1);
	if (IS_ERR(p->mutex))
		return PTR_ERR(p->mutex);
	res = platform_get_resource(pdev, IORESOURCE_MEM, 2);
	if (!res || (resource_size_t)stride * height > resource_size(res))
		return dev_err_probe(d, -EINVAL, "framebuffer region missing or too small\n");
	p->paddr = res->start;
	p->stride = stride;
	/* ordinary RAM: the linear map's attributes, not ioremap */
	p->vaddr = devm_memremap(d, res->start, (size_t)stride * height, MEMREMAP_WB);
	if (IS_ERR(p->vaddr))
		return dev_err_probe(d, PTR_ERR(p->vaddr), "cannot map framebuffer\n");

	/* the mode starts on a page (shadow buffers are page-based anyway) */
	while (((size_t)top_margin * stride) % PAGE_SIZE && top_margin < height)
		top_margin++;
	if (top_margin + bottom_margin >= height / 2) {
		drm_warn(dev, "margins %u/%u too large, ignored\n", top_margin, bottom_margin);
		top_margin = 0;
		bottom_margin = 0;
	}
	p->first_row = top_margin;
	rows = height - top_margin - bottom_margin;

	sysfb->fb_mode = drm_sysfb_mode(width, rows, 68, 152 * rows / height);
	sysfb->fb_format = drm_format_info(DRM_FORMAT_XRGB8888);
	sysfb->fb_pitch = stride;
	iosys_map_set_vaddr(&sysfb->fb_addr, p->vaddr + (size_t)top_margin * stride);

	pacman_drm_find_mutex(p);
	pacman_drm_scan_ovls(p);

	spin_lock_init(&p->dirty_lock);
	p->dirty_y1 = INT_MAX;
	INIT_DELAYED_WORK(&p->kick_work, pacman_drm_kick_work);
	ret = devm_add_action_or_reset(d, pacman_drm_cancel_kicks, p);
	if (ret)
		return ret;

	/* rows outside the mode stay black */
	memset(p->vaddr, 0, (size_t)top_margin * stride);
	memset(p->vaddr + (size_t)(height - bottom_margin) * stride, 0,
	       (size_t)bottom_margin * stride);
	dcache_clean_poc((unsigned long)p->vaddr,
			 (unsigned long)p->vaddr + (size_t)stride * height);

	ret = pacman_drm_mode_config_init(p);
	if (ret)
		return ret;
	drm_mode_config_reset(dev);

	ret = drm_dev_register(dev, 0);
	if (ret)
		return ret;

	drm_info(dev, "%ux%u (panel rows %u-%u) at %pa, mutex %d\n", width, rows,
		 top_margin, height - bottom_margin - 1, &p->paddr, p->mutex_id);

	drm_client_setup(dev, sysfb->fb_format);
	return 0;
}

static void pacman_drm_remove(struct platform_device *pdev)
{
	struct pacman_drm *p = platform_get_drvdata(pdev);

	drm_dev_unplug(&p->sysfb.dev);
}

static const struct of_device_id pacman_drm_of_match[] = {
	{ .compatible = "nothing,pacman-cmdfb" },
	{ }
};
MODULE_DEVICE_TABLE(of, pacman_drm_of_match);

static struct platform_driver pacman_drm_platform_driver = {
	.driver = {
		.name = DRIVER_NAME,
		.of_match_table = pacman_drm_of_match,
	},
	.probe = pacman_drm_probe,
	.remove = pacman_drm_remove,
};
module_platform_driver(pacman_drm_platform_driver);

MODULE_DESCRIPTION(DRIVER_DESC);
MODULE_LICENSE("GPL");
