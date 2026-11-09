/*
 * pacman-reboot: reboot with a mode string, like Android's `reboot bootloader`.
 *
 *   pacman-reboot               normal reboot
 *   pacman-reboot bootloader    reboot into LK fastboot
 *   pacman-reboot recovery      reboot into recovery
 *   pacman-reboot poweroff      power off
 *
 * The kernel's syscon-reboot-mode driver (DT: watchdog@1c007000/reboot-mode,
 * TOPRGU offset 0x24) stores the mode where LK reads it on the next boot.
 * busybox `reboot` cannot pass a mode string, hence this helper.
 */
#include <linux/reboot.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

static long do_reboot(unsigned int cmd, const char *arg)
{
	return syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2, cmd, arg);
}

int main(int argc, char **argv)
{
	const char *mode = argc > 1 ? argv[1] : NULL;

	if (mode && (!strcmp(mode, "-h") || !strcmp(mode, "--help"))) {
		puts("usage: pacman-reboot [bootloader|recovery|poweroff]");
		return 0;
	}

	sync();
	if (!mode)
		do_reboot(LINUX_REBOOT_CMD_RESTART, NULL);
	else if (!strcmp(mode, "poweroff"))
		do_reboot(LINUX_REBOOT_CMD_POWER_OFF, NULL);
	else
		do_reboot(LINUX_REBOOT_CMD_RESTART2, mode);

	perror("pacman-reboot");
	return 1;
}
