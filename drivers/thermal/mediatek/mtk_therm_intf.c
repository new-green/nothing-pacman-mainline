// SPDX-License-Identifier: GPL-2.0-only
/*
 * Temperatures published by the MediaTek MCUPM thermal firmware.
 *
 * On recent MediaTek phone SoCs (e.g. MT6886 / Dimensity 7200) the LVTS
 * sensors are run by firmware on the MCUPM co-processor, which the
 * bootloader starts. The firmware writes the current temperatures into a
 * small SRAM window ("therm_sram", DT node compatible "mediatek,therm_intf"),
 * as signed 32-bit millidegrees Celsius:
 *
 *   0x000 + 4 * n   CPU n
 *   0x180           GPU
 *
 * This driver only reads that window and registers one thermal zone per
 * sensor. Each zone has a critical trip (module parameter crit_temp) so the
 * kernel powers the device off if it ever overheats while nothing else
 * manages thermals. It never writes to the SRAM.
 */

#include <linux/io.h>
#include <linux/math.h>
#include <linux/mod_devicetable.h>
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/thermal.h>

#define TI_CPU_TEMP(n)		(0x000 + 4 * (n))
#define TI_GPU_TEMP		0x180
#define TI_NUM_CPUS		8

/* the firmware leaves 0x27bc86aa (666666666) in unused slots */
#define TI_TEMP_MIN		(-40000)
#define TI_TEMP_MAX		200000

#define TI_POLL_MS		1000

static int crit_temp = 95000;
module_param(crit_temp, int, 0444);
MODULE_PARM_DESC(crit_temp, "Critical (power-off) temperature in millidegrees C, default 95000");

struct mtk_ti_sensor {
	void __iomem *reg;
	const char *name;
};

static int mtk_ti_read(void __iomem *reg, int *temp)
{
	s32 v = (s32)readl(reg);

	if (v < TI_TEMP_MIN || v > TI_TEMP_MAX)
		return -EAGAIN;

	*temp = v;
	return 0;
}

static int mtk_ti_get_temp(struct thermal_zone_device *tz, int *temp)
{
	struct mtk_ti_sensor *s = thermal_zone_device_priv(tz);

	return mtk_ti_read(s->reg, temp);
}

static const struct thermal_zone_device_ops mtk_ti_ops = {
	.get_temp = mtk_ti_get_temp,
};

static void mtk_ti_unregister(void *tz)
{
	thermal_zone_device_unregister(tz);
}

static int mtk_ti_add_zone(struct device *dev, void __iomem *base,
			   unsigned int offset, const char *name)
{
	struct thermal_trip trip = {
		.temperature = crit_temp,
		.type = THERMAL_TRIP_CRITICAL,
	};
	struct thermal_zone_device *tz;
	struct mtk_ti_sensor *s;
	int temp, ret;

	s = devm_kzalloc(dev, sizeof(*s), GFP_KERNEL);
	if (!s)
		return -ENOMEM;
	s->reg = base + offset;
	s->name = name;

	/* skip slots the firmware does not fill on this SoC */
	if (mtk_ti_read(s->reg, &temp)) {
		dev_dbg(dev, "%s: no valid reading, skipped\n", name);
		return 0;
	}

	tz = thermal_zone_device_register_with_trips(name, &trip, 1, s,
						     &mtk_ti_ops, NULL,
						     0, TI_POLL_MS);
	if (IS_ERR(tz))
		return dev_err_probe(dev, PTR_ERR(tz), "%s: cannot register zone\n", name);

	ret = devm_add_action_or_reset(dev, mtk_ti_unregister, tz);
	if (ret)
		return ret;

	ret = thermal_zone_device_enable(tz);
	if (ret)
		return ret;

	dev_info(dev, "%s: %d.%03d C\n", name, temp / 1000, abs(temp % 1000));
	return 1;
}

static int mtk_ti_probe(struct platform_device *pdev)
{
	static const char * const cpu_names[TI_NUM_CPUS] = {
		"cpu0-thermal", "cpu1-thermal", "cpu2-thermal", "cpu3-thermal",
		"cpu4-thermal", "cpu5-thermal", "cpu6-thermal", "cpu7-thermal",
	};
	struct device *dev = &pdev->dev;
	void __iomem *base;
	int i, ret, zones = 0;

	base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(base))
		return PTR_ERR(base);

	for (i = 0; i < TI_NUM_CPUS; i++) {
		ret = mtk_ti_add_zone(dev, base, TI_CPU_TEMP(i), cpu_names[i]);
		if (ret < 0)
			return ret;
		zones += ret;
	}

	ret = mtk_ti_add_zone(dev, base, TI_GPU_TEMP, "gpu-thermal");
	if (ret < 0)
		return ret;
	zones += ret;

	if (!zones)
		return dev_err_probe(dev, -ENODEV,
				     "no valid temperatures (thermal firmware not running?)\n");

	dev_info(dev, "%d zones, critical at %d.%03d C\n", zones,
		 crit_temp / 1000, abs(crit_temp % 1000));
	return 0;
}

static const struct of_device_id mtk_ti_of_match[] = {
	{ .compatible = "mediatek,therm_intf" },
	{ }
};
MODULE_DEVICE_TABLE(of, mtk_ti_of_match);

static struct platform_driver mtk_ti_driver = {
	.probe = mtk_ti_probe,
	.driver = {
		.name = "mtk-therm-intf",
		.of_match_table = mtk_ti_of_match,
	},
};
module_platform_driver(mtk_ti_driver);

MODULE_DESCRIPTION("MediaTek MCUPM thermal firmware temperature reader");
MODULE_LICENSE("GPL");
