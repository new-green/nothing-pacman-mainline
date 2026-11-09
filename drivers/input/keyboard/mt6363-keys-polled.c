// SPDX-License-Identifier: GPL-2.0-only
/*
 * Power and home keys of the MediaTek MT6363 PMIC on SPMI, polled.
 *
 * Mainline has no MT6363 core (MFD + interrupt controller) driver yet, so
 * instead of PMIC interrupts this reads the debounced key status in
 * TOPSTATUS while the input device is open. It only ever reads from the
 * PMIC. Bring-up driver for MT6886 (Nothing Phone (2a)): it binds the
 * "mediatek,mt6363" SPMI device directly and must give way to a real
 * MT6363 core driver once one exists.
 */

#include <linux/bits.h>
#include <linux/input.h>
#include <linux/mod_devicetable.h>
#include <linux/module.h>
#include <linux/regmap.h>
#include <linux/spmi.h>

#define MT6363_SWCID		0x000b
#define MT6363_TOPSTATUS	0x001e
#define MT6363_CHIP_ID		0x63

#define MT6363_KEYS_POLL_MS	20

/* TOPSTATUS: debounced key state, the bit is clear while the key is pressed */
static const struct {
	u32 mask;
	unsigned int code;
} mt6363_keys[] = {
	{ BIT(1), KEY_POWER },		/* power key */
	{ BIT(3), KEY_VOLUMEUP },	/* "home" key, volume up on this phone */
};

struct mt6363_keys {
	struct regmap *map;
	struct input_dev *input;
};

static void mt6363_keys_poll(struct input_dev *input)
{
	struct mt6363_keys *k = input_get_drvdata(input);
	unsigned int val;
	int i;

	if (regmap_read(k->map, MT6363_TOPSTATUS, &val))
		return;

	for (i = 0; i < ARRAY_SIZE(mt6363_keys); i++)
		input_report_key(input, mt6363_keys[i].code, !(val & mt6363_keys[i].mask));
	input_sync(input);
}

static const struct regmap_config mt6363_keys_regmap_config = {
	.reg_bits	= 16,
	.val_bits	= 8,
	.max_register	= 0x0fff,
};

static int mt6363_keys_probe(struct spmi_device *sdev)
{
	struct device *dev = &sdev->dev;
	struct mt6363_keys *k;
	unsigned int id, status;
	int i, ret;

	k = devm_kzalloc(dev, sizeof(*k), GFP_KERNEL);
	if (!k)
		return -ENOMEM;

	k->map = devm_regmap_init_spmi_ext(sdev, &mt6363_keys_regmap_config);
	if (IS_ERR(k->map))
		return dev_err_probe(dev, PTR_ERR(k->map), "cannot create regmap\n");

	ret = regmap_read(k->map, MT6363_SWCID, &id);
	if (ret)
		return dev_err_probe(dev, ret, "cannot read chip id over SPMI\n");
	if (id != MT6363_CHIP_ID)
		return dev_err_probe(dev, -ENODEV, "unexpected chip id 0x%02x\n", id);

	ret = regmap_read(k->map, MT6363_TOPSTATUS, &status);
	if (ret)
		return dev_err_probe(dev, ret, "cannot read TOPSTATUS\n");
	dev_info(dev, "MT6363 (chip id 0x%02x) on SPMI usid %u, TOPSTATUS 0x%02x\n",
		 id, sdev->usid, status);

	k->input = devm_input_allocate_device(dev);
	if (!k->input)
		return -ENOMEM;

	k->input->name = "mt6363-keys";
	k->input->phys = "mt6363-keys/input0";
	k->input->id.bustype = BUS_HOST;
	input_set_drvdata(k->input, k);
	for (i = 0; i < ARRAY_SIZE(mt6363_keys); i++)
		input_set_capability(k->input, EV_KEY, mt6363_keys[i].code);

	ret = input_setup_polling(k->input, mt6363_keys_poll);
	if (ret)
		return ret;
	input_set_poll_interval(k->input, MT6363_KEYS_POLL_MS);

	return input_register_device(k->input);
}

static const struct of_device_id mt6363_keys_of_match[] = {
	{ .compatible = "mediatek,mt6363" },
	{ }
};
MODULE_DEVICE_TABLE(of, mt6363_keys_of_match);

static struct spmi_driver mt6363_keys_driver = {
	.probe = mt6363_keys_probe,
	.driver = {
		.name = "mt6363-keys-polled",
		.of_match_table = mt6363_keys_of_match,
	},
};
module_spmi_driver(mt6363_keys_driver);

MODULE_DESCRIPTION("MediaTek MT6363 PMIC keys (polled, SPMI)");
MODULE_LICENSE("GPL");
