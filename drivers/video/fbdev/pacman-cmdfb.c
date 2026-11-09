// SPDX-License-Identifier: GPL-2.0-only
/*
 * Nothing Phone (2a) "Pacman": framebuffer for the bootloader's display
 * pipeline on a DSI command-mode panel.
 *
 * The bootloader (LK) sets up OVL/RDMA -> DSI0 -> panel and leaves the
 * splash framebuffer in a reserved RAM region it marks as mapped, so
 * simple-framebuffer cannot ioremap it. On a command-mode panel the panel
 * also only takes a new frame when the display engine is told to send one.
 *
 * This driver:
 *  - maps the framebuffer as normal (cached) memory and registers fb0,
 *  - periodically cleans the CPU cache over it and kicks one frame out
 *    (display mutex enable + DSI_START), the same writes MediaTek's own
 *    driver uses for a command-mode frame,
 *  - dumps the relevant DSI / mutex registers to the kernel log.
 *
 * Bring-up hack, not meant for upstream as is.
 */

#include <linux/delay.h>
#include <linux/fb.h>
#include <linux/io.h>
#include <linux/mm.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/workqueue.h>
#include <asm/cacheflush.h>

#define DSI_START		0x00
#define DSI_INTSTA		0x0c
#define DSI_MODE_CTRL		0x14

#define MUTEX_EN(n)		(0x20 + 0x20 * (n))
#define MUTEX_SOF(n)		(0x2c + 0x20 * (n))
#define MUTEX_MOD0(n)		(0x30 + 0x20 * (n))
#define MUTEX_MAX		16

#define REFRESH_MS		50

struct pacman_cmdfb {
	struct device *dev;
	void __iomem *dsi;
	void __iomem *mutex;
	void *vaddr;
	phys_addr_t paddr;
	size_t visible;
	int mutex_id;
	struct fb_info *info;
	struct delayed_work work;
	u32 pseudo_palette[16];
};

static void pacman_cmdfb_kick(struct pacman_cmdfb *p)
{
	unsigned long start = (unsigned long)p->vaddr;

	/* make what the CPU drew visible to the display engine */
	dcache_clean_poc(start, start + p->visible);

	if (p->mutex_id >= 0)
		writel(1, p->mutex + MUTEX_EN(p->mutex_id));
	writel(0, p->dsi + DSI_START);
	writel(1, p->dsi + DSI_START);
}

static void pacman_cmdfb_work(struct work_struct *w)
{
	struct pacman_cmdfb *p = container_of(to_delayed_work(w),
					      struct pacman_cmdfb, work);

	pacman_cmdfb_kick(p);
	schedule_delayed_work(&p->work, msecs_to_jiffies(REFRESH_MS));
}

static int pacman_cmdfb_setcolreg(unsigned int regno, unsigned int red,
				  unsigned int green, unsigned int blue,
				  unsigned int transp, struct fb_info *info)
{
	u32 *pal = info->pseudo_palette;

	if (regno >= 16)
		return -EINVAL;

	pal[regno] = 0xff000000 |
		     ((red >> 8) << info->var.red.offset) |
		     ((green >> 8) << info->var.green.offset) |
		     ((blue >> 8) << info->var.blue.offset);
	return 0;
}

/*
 * Map the framebuffer with the vma's default (cacheable) attributes, i.e. the
 * same as the kernel's MEMREMAP_WB alias: no mismatched aliases, and the
 * refresh worker's dcache_clean_poc() pushes user writes to the display.
 */
static int pacman_cmdfb_mmap(struct fb_info *info, struct vm_area_struct *vma)
{
	struct pacman_cmdfb *p = info->par;

	return vm_iomap_memory(vma, p->paddr, p->visible);
}

static const struct fb_ops pacman_cmdfb_ops = {
	.owner		= THIS_MODULE,
	.fb_read	= fb_sys_read,
	.fb_write	= fb_sys_write,
	.fb_fillrect	= sys_fillrect,
	.fb_copyarea	= sys_copyarea,
	.fb_imageblit	= sys_imageblit,
	.fb_setcolreg	= pacman_cmdfb_setcolreg,
	.fb_mmap	= pacman_cmdfb_mmap,
};

static void pacman_cmdfb_dump(struct pacman_cmdfb *p)
{
	int i;

	dev_info(p->dev, "DSI: START=%08x INTSTA=%08x MODE_CTRL=%08x (0 = command mode)\n",
		 readl(p->dsi + DSI_START), readl(p->dsi + DSI_INTSTA),
		 readl(p->dsi + DSI_MODE_CTRL));

	p->mutex_id = -1;
	for (i = 0; i < MUTEX_MAX; i++) {
		u32 en = readl(p->mutex + MUTEX_EN(i));
		u32 sof = readl(p->mutex + MUTEX_SOF(i));
		u32 mod = readl(p->mutex + MUTEX_MOD0(i));

		if (en || sof || mod)
			dev_info(p->dev, "mutex%d: EN=%08x SOF=%08x MOD0=%08x\n",
				 i, en, sof, mod);
		if (p->mutex_id < 0 && mod)
			p->mutex_id = i;
	}
	dev_info(p->dev, "using mutex %d\n", p->mutex_id);
}

static int pacman_cmdfb_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct device_node *np = dev->of_node;
	struct pacman_cmdfb *p;
	struct fb_info *info;
	struct resource *res;
	u32 width, height, stride;
	int ret;

	if (of_property_read_u32(np, "width", &width) ||
	    of_property_read_u32(np, "height", &height) ||
	    of_property_read_u32(np, "stride", &stride))
		return dev_err_probe(dev, -EINVAL, "width/height/stride missing\n");

	info = framebuffer_alloc(sizeof(*p), dev);
	if (!info)
		return -ENOMEM;
	p = info->par;
	p->dev = dev;
	p->info = info;

	/* regs: 0 = DSI0, 1 = display mutex, 2 = framebuffer */
	res = platform_get_resource(pdev, IORESOURCE_MEM, 0);
	p->dsi = res ? devm_ioremap(dev, res->start, resource_size(res)) : NULL;
	res = platform_get_resource(pdev, IORESOURCE_MEM, 1);
	p->mutex = res ? devm_ioremap(dev, res->start, resource_size(res)) : NULL;
	res = platform_get_resource(pdev, IORESOURCE_MEM, 2);
	if (!p->dsi || !p->mutex || !res) {
		ret = dev_err_probe(dev, -EINVAL, "missing reg entries\n");
		goto err_release;
	}

	p->paddr = res->start;
	p->visible = (size_t)stride * height;
	if (p->visible > resource_size(res)) {
		ret = dev_err_probe(dev, -EINVAL, "framebuffer region too small\n");
		goto err_release;
	}

	/* The region is ordinary mapped RAM: use the linear map, not ioremap */
	p->vaddr = devm_memremap(dev, res->start, resource_size(res), MEMREMAP_WB);
	if (IS_ERR(p->vaddr)) {
		ret = dev_err_probe(dev, PTR_ERR(p->vaddr), "cannot map framebuffer\n");
		goto err_release;
	}

	pacman_cmdfb_dump(p);

	strscpy(info->fix.id, "pacman-cmdfb", sizeof(info->fix.id));
	info->fix.type = FB_TYPE_PACKED_PIXELS;
	info->fix.visual = FB_VISUAL_TRUECOLOR;
	info->fix.smem_start = p->paddr;
	info->fix.smem_len = p->visible;
	info->fix.line_length = stride;

	info->var.xres = width;
	info->var.yres = height;
	info->var.xres_virtual = width;
	info->var.yres_virtual = height;
	info->var.bits_per_pixel = 32;
	info->var.transp = (struct fb_bitfield){ 24, 8, 0 };
	info->var.red = (struct fb_bitfield){ 16, 8, 0 };
	info->var.green = (struct fb_bitfield){ 8, 8, 0 };
	info->var.blue = (struct fb_bitfield){ 0, 8, 0 };
	info->var.activate = FB_ACTIVATE_NOW;
	info->var.vmode = FB_VMODE_NONINTERLACED;
	info->var.height = 152;	/* mm, roughly */
	info->var.width = 68;

	info->fbops = &pacman_cmdfb_ops;
	info->flags = FBINFO_VIRTFB;
	info->screen_buffer = p->vaddr;
	info->screen_size = p->visible;
	info->pseudo_palette = p->pseudo_palette;

	/* Start from a known state: a dark grey screen means "driver is alive" */
	memset(p->vaddr, 0x20, p->visible);
	pacman_cmdfb_kick(p);

	INIT_DELAYED_WORK(&p->work, pacman_cmdfb_work);
	schedule_delayed_work(&p->work, msecs_to_jiffies(REFRESH_MS));

	ret = register_framebuffer(info);
	if (ret) {
		dev_err(dev, "register_framebuffer failed: %d\n", ret);
		goto err_work;
	}

	platform_set_drvdata(pdev, p);
	dev_info(dev, "fb%d: %ux%u stride %u at %pa, refresh every %d ms\n",
		 info->node, width, height, stride, &p->paddr, REFRESH_MS);
	return 0;

err_work:
	cancel_delayed_work_sync(&p->work);
err_release:
	framebuffer_release(info);
	return ret;
}

static const struct of_device_id pacman_cmdfb_of_match[] = {
	{ .compatible = "nothing,pacman-cmdfb" },
	{ }
};

static struct platform_driver pacman_cmdfb_driver = {
	.probe = pacman_cmdfb_probe,
	.driver = {
		.name = "pacman-cmdfb",
		.of_match_table = pacman_cmdfb_of_match,
		.suppress_bind_attrs = true,
	},
};
builtin_platform_driver(pacman_cmdfb_driver);
