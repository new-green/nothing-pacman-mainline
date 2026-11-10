/*
 * pacman-keysd: makes the phone's hardware keys do something without a PC.
 *
 *   power (short press)  blank / unblank the panel (FBIOBLANK on /dev/fb0;
 *                        pacman-cmdfb switches its OVL layer off, so the OLED
 *                        pixels are really off)
 *   any key while blank  unblank (the key press is not acted on otherwise)
 *
 * Volume up/down are only logged here; under Xorg they arrive as the usual
 * XF86AudioRaiseVolume / XF86AudioLowerVolume keys through the evdev driver.
 *
 * Reads every /dev/input/event* that reports KEY_POWER, KEY_VOLUMEUP or
 * KEY_VOLUMEDOWN (mt6363-keys-polled, mt6779-keypad). Does not grab them.
 * Started by /pacman-init. Log lines go to /dev/kmsg ("pacman-keysd: ...").
 */
#include <fcntl.h>
#include <linux/fb.h>
#include <linux/input.h>
#include <poll.h>
#include <stdarg.h>
#include <stdio.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#define MAX_DEVS	8
#define LONG_PRESS_MS	1500	/* longer presses are left to the PMIC / ignored */

static void klog(const char *fmt, ...)
{
	char buf[160];
	va_list ap;
	int n, fd;

	n = snprintf(buf, sizeof(buf), "pacman-keysd: ");
	va_start(ap, fmt);
	n += vsnprintf(buf + n, sizeof(buf) - n, fmt, ap);
	va_end(ap);
	if (n > (int)sizeof(buf) - 1)
		n = sizeof(buf) - 1;
	fd = open("/dev/kmsg", O_WRONLY);
	if (fd >= 0) {
		ssize_t w = write(fd, buf, n);

		(void)w;
		close(fd);
	}
}

static long long now_ms(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec * 1000LL + t.tv_nsec / 1000000;
}

static int has_key(int fd, int code)
{
	unsigned long bits[KEY_MAX / (8 * sizeof(long)) + 1] = { 0 };

	if (ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(bits)), bits) < 0)
		return 0;
	return (bits[code / (8 * sizeof(long))] >> (code % (8 * sizeof(long)))) & 1;
}

static int set_blank(int blank)
{
	int fd = open("/dev/fb0", O_RDWR), ret;

	if (fd < 0)
		return -1;
	ret = ioctl(fd, FBIOBLANK, blank ? FB_BLANK_POWERDOWN : FB_BLANK_UNBLANK);
	close(fd);
	return ret;
}

int main(void)
{
	struct pollfd pfd[MAX_DEVS];
	int ndev = 0, blanked = 0;
	long long power_down_at = 0;

	for (int i = 0; i < 32 && ndev < MAX_DEVS; i++) {
		char path[32], name[64] = "?";
		int fd;

		snprintf(path, sizeof(path), "/dev/input/event%d", i);
		fd = open(path, O_RDONLY | O_NONBLOCK);
		if (fd < 0)
			continue;
		if (!has_key(fd, KEY_POWER) && !has_key(fd, KEY_VOLUMEUP) &&
		    !has_key(fd, KEY_VOLUMEDOWN)) {
			close(fd);
			continue;
		}
		ioctl(fd, EVIOCGNAME(sizeof(name)), name);
		klog("%s (%s)\n", path, name);
		pfd[ndev].fd = fd;
		pfd[ndev].events = POLLIN;
		ndev++;
	}
	if (!ndev) {
		klog("no key devices found\n");
		return 1;
	}

	for (;;) {
		if (poll(pfd, ndev, -1) < 0)
			continue;
		for (int d = 0; d < ndev; d++) {
			struct input_event ev;

			if (!(pfd[d].revents & POLLIN))
				continue;
			while (read(pfd[d].fd, &ev, sizeof(ev)) == sizeof(ev)) {
				if (ev.type != EV_KEY || ev.value == 2)
					continue;

				if (ev.code != KEY_POWER) {
					if (ev.value == 1 && blanked && !set_blank(0)) {
						blanked = 0;
						klog("unblank (key %d)\n", ev.code);
					}
					continue;
				}
				if (ev.value == 1) {
					power_down_at = now_ms();
					continue;
				}
				/* power released */
				if (!power_down_at || now_ms() - power_down_at > LONG_PRESS_MS) {
					power_down_at = 0;
					continue;
				}
				power_down_at = 0;
				if (set_blank(!blanked)) {
					klog("FBIOBLANK failed\n");
					continue;
				}
				blanked = !blanked;
				klog("%s\n", blanked ? "blank" : "unblank");
			}
		}
	}
}
