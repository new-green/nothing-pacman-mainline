// SPDX-License-Identifier: GPL-2.0-only
/*
 * pacman-dash: a tiny live system dashboard drawn straight into /dev/fb0.
 *
 * Runs as /init from the kernel's built-in initramfs on the Nothing Phone (2a)
 * mainline bring-up. No input devices yet, so it only shows things:
 * kernel, uptime, per-core CPU load, memory, load average. A core's bar turns
 * red above 80 % load.
 *
 * Build:  aarch64-linux-gnu-gcc -O2 -static -o pacman-dash pacman-dash.c
 * Preview on a PC (writes a PPM image instead of using /dev/fb0):
 *         gcc -O2 -o dash-preview pacman-dash.c && PACMAN_PREVIEW=out.ppm ./dash-preview
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <linux/kd.h>
#include <limits.h>
#include <math.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "font8x16.h"

#define MAX_CPUS	8

/* colours, 0xAARRGGBB (a8r8g8b8) */
#define C_BG		0xff000000u
#define C_FG		0xffffffffu
#define C_DIM		0xff8a8a8au
#define C_TRACK		0xff262626u
#define C_RED		0xffd71921u

static uint32_t *fb_mem;	/* mapped framebuffer (or preview buffer) */
static uint32_t *buf;		/* back buffer */
static int W, H, pitch_px;	/* pitch in pixels */

/* ------------------------------------------------------------------ drawing */

static void fill(int x, int y, int w, int h, uint32_t c)
{
	if (x < 0) { w += x; x = 0; }
	if (y < 0) { h += y; y = 0; }
	if (x + w > W) w = W - x;
	if (y + h > H) h = H - y;
	for (int j = 0; j < h; j++) {
		uint32_t *p = buf + (y + j) * W + x;
		for (int i = 0; i < w; i++)
			p[i] = c;
	}
}

static void disc(int cx, int cy, int r, uint32_t c)
{
	for (int dy = -r; dy <= r; dy++)
		for (int dx = -r; dx <= r; dx++)
			if (dx * dx + dy * dy <= r * r) {
				int x = cx + dx, y = cy + dy;
				if (x >= 0 && x < W && y >= 0 && y < H)
					buf[y * W + x] = c;
			}
}

/* blocky text, scale s: each font pixel is an s x s square */
static int text(int x, int y, int s, uint32_t c, const char *str)
{
	for (; *str; str++, x += 8 * s) {
		unsigned ch = (unsigned char)*str;
		if (ch < 32 || ch > 127)
			ch = '?';
		const unsigned char *g = font8x16[ch - 32];
		for (int row = 0; row < 16; row++)
			for (int col = 0; col < 8; col++)
				if (g[row] & (0x80 >> col))
					fill(x + col * s, y + row * s, s, s, c);
	}
	return x;
}

/* 5x7 dot-matrix glyphs for the header (rows, 5 bits each, MSB = left) */
struct dotglyph { char ch; unsigned char row[7]; };
static const struct dotglyph dotfont[] = {
	{ ' ', { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 } },
	{ '(', { 0x02, 0x04, 0x08, 0x08, 0x08, 0x04, 0x02 } },
	{ ')', { 0x08, 0x04, 0x02, 0x02, 0x02, 0x04, 0x08 } },
	{ '2', { 0x0e, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1f } },
	{ 'A', { 0x0e, 0x11, 0x11, 0x1f, 0x11, 0x11, 0x11 } },
	{ 'E', { 0x1f, 0x10, 0x10, 0x1e, 0x10, 0x10, 0x1f } },
	{ 'H', { 0x11, 0x11, 0x11, 0x1f, 0x11, 0x11, 0x11 } },
	{ 'N', { 0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11 } },
	{ 'O', { 0x0e, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0e } },
	{ 'P', { 0x1e, 0x11, 0x11, 0x1e, 0x10, 0x10, 0x10 } },
};

/* dot-matrix text: pitch = distance between dot centres */
static void dots(int x, int y, int pitch, uint32_t c, const char *str)
{
	int r = pitch * 3 / 8;
	for (; *str; str++, x += 6 * pitch) {
		const struct dotglyph *g = NULL;
		for (size_t i = 0; i < sizeof(dotfont) / sizeof(dotfont[0]); i++)
			if (dotfont[i].ch == *str)
				g = &dotfont[i];
		if (!g)
			continue;
		for (int row = 0; row < 7; row++)
			for (int col = 0; col < 5; col++)
				if (g->row[row] & (0x10 >> col))
					disc(x + col * pitch + pitch / 2, y + row * pitch + pitch / 2, r, c);
	}
}

static void bar(int x, int y, int w, int h, double frac, uint32_t c)
{
	if (frac < 0) frac = 0;
	if (frac > 1) frac = 1;
	fill(x, y, w, h, C_TRACK);
	fill(x, y, (int)(w * frac + 0.5), h, c);
}

static void present(void)
{
	for (int y = 0; y < H; y++)
		memcpy(fb_mem + y * pitch_px, buf + y * W, W * 4);
}

/* ------------------------------------------------------------- system info */

struct cpustat { unsigned long long busy, total; };

static int read_cpustat(struct cpustat *st, int max)
{
	FILE *f = fopen("/proc/stat", "r");
	char line[512];
	int n = 0;

	if (!f)
		return 0;
	while (fgets(line, sizeof(line), f)) {
		int id;
		unsigned long long v[10] = { 0 };
		if (sscanf(line, "cpu%d %llu %llu %llu %llu %llu %llu %llu %llu",
			   &id, &v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &v[6], &v[7]) >= 5 &&
		    id >= 0 && id < max) {
			unsigned long long idle = v[3] + v[4];
			unsigned long long tot = 0;
			for (int i = 0; i < 8; i++)
				tot += v[i];
			st[id].busy = tot - idle;
			st[id].total = tot;
			if (id + 1 > n)
				n = id + 1;
		}
	}
	fclose(f);
	return n;
}

static void read_cpu_parts(const char **part, int max)
{
	FILE *f = fopen("/proc/cpuinfo", "r");
	char line[256];
	int cur = -1;

	for (int i = 0; i < max; i++)
		part[i] = "?";
	if (!f)
		return;
	while (fgets(line, sizeof(line), f)) {
		unsigned p;
		if (sscanf(line, "processor : %d", &cur) == 1)
			continue;
		if (cur >= 0 && cur < max && sscanf(line, "CPU part : 0x%x", &p) == 1)
			part[cur] = p == 0xd46 ? "A510" : p == 0xd4d ? "A715" :
				    p == 0xd05 ? "A55" : p == 0xd41 ? "A78" : "core";
	}
	fclose(f);
}

static unsigned long long meminfo(const char *key)
{
	FILE *f = fopen("/proc/meminfo", "r");
	char line[256];
	unsigned long long v = 0;
	size_t kl = strlen(key);

	if (!f)
		return 0;
	while (fgets(line, sizeof(line), f))
		if (!strncmp(line, key, kl) && line[kl] == ':') {
			sscanf(line + kl + 1, "%llu", &v);
			break;
		}
	fclose(f);
	return v;	/* kB */
}

static double uptime_s(void)
{
	FILE *f = fopen("/proc/uptime", "r");
	double u = 0;
	if (f) {
		if (fscanf(f, "%lf", &u) != 1)
			u = 0;
		fclose(f);
	}
	return u;
}

static void loadavg(char *out, size_t n)
{
	FILE *f = fopen("/proc/loadavg", "r");
	double a = 0, b = 0, c = 0;
	if (f) {
		if (fscanf(f, "%lf %lf %lf", &a, &b, &c) != 3)
			a = b = c = 0;
		fclose(f);
	}
	snprintf(out, n, "%.2f  %.2f  %.2f", a, b, c);
}

/*
 * Temperatures from the kernel's thermal zones (mtk_therm_intf driver:
 * types "cpu0-thermal".."cpu7-thermal" and "gpu-thermal").
 * cpu_tz[c] / gpu_tz hold the zone's temp file path, empty if missing.
 */
static char cpu_tz[MAX_CPUS][64], gpu_tz[64];

static void find_thermal_zones(void)
{
	for (int i = 0; i < 64; i++) {
		char path[64], type[32] = "";
		int cpu;
		FILE *f;

		snprintf(path, sizeof(path), "/sys/class/thermal/thermal_zone%d/type", i);
		f = fopen(path, "r");
		if (!f)
			continue;
		if (!fgets(type, sizeof(type), f))
			type[0] = 0;
		fclose(f);
		snprintf(path, sizeof(path), "/sys/class/thermal/thermal_zone%d/temp", i);
		if (sscanf(type, "cpu%d-thermal", &cpu) == 1 && cpu >= 0 && cpu < MAX_CPUS)
			snprintf(cpu_tz[cpu], sizeof(cpu_tz[cpu]), "%s", path);
		else if (!strncmp(type, "gpu-thermal", 11))
			snprintf(gpu_tz, sizeof(gpu_tz), "%s", path);
	}
}

/* millidegrees C, or INT_MIN if unavailable */
static int read_temp(const char *path)
{
	FILE *f;
	int t;

	if (!path[0] || !(f = fopen(path, "r")))
		return INT_MIN;
	if (fscanf(f, "%d", &t) != 1)
		t = INT_MIN;
	fclose(f);
	return t;
}

#define TEMP_HOT	60000	/* drawn in red from here */

/* "37.9°C" (the font has no degree sign: draw a small ring) */
static void temp_text(int x, int y, int scale, int mdeg)
{
	char s[16];
	uint32_t col = mdeg >= TEMP_HOT ? C_RED : C_FG;

	if (mdeg == INT_MIN) {
		text(x, y, scale, C_DIM, "--");
		return;
	}
	snprintf(s, sizeof(s), "%.1f", mdeg / 1000.0);
	text(x, y, scale, col, s);
	x += (int)strlen(s) * 8 * scale + 3 * scale;
	disc(x + 2 * scale, y + 4 * scale, 2 * scale, col);
	disc(x + 2 * scale, y + 4 * scale, scale, C_BG);
	text(x + 5 * scale, y, scale, col, "C");
}

/* ------------------------------------------------------------------- setup */

static void early_mounts(void)
{
	mkdir("/proc", 0755);
	mkdir("/sys", 0755);
	mkdir("/dev", 0755);
	mount("proc", "/proc", "proc", 0, NULL);
	mount("sysfs", "/sys", "sysfs", 0, NULL);
	mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
}

static int open_fb(void)
{
	struct fb_var_screeninfo var;
	struct fb_fix_screeninfo fix;
	int fd = -1;

	for (int i = 0; i < 50 && fd < 0; i++) {	/* wait up to 5 s for fb0 */
		fd = open("/dev/fb0", O_RDWR);
		if (fd < 0)
			usleep(100000);
	}
	if (fd < 0 || ioctl(fd, FBIOGET_VSCREENINFO, &var) || ioctl(fd, FBIOGET_FSCREENINFO, &fix))
		return -1;
	if (var.bits_per_pixel != 32)
		return -1;

	W = var.xres;
	H = var.yres;
	pitch_px = fix.line_length / 4;
	fb_mem = mmap(NULL, fix.line_length * H, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (fb_mem == MAP_FAILED)
		return -1;

	/* keep the text console from drawing over us */
	int tty = open("/dev/tty0", O_RDWR);
	if (tty >= 0)
		ioctl(tty, KDSETMODE, KD_GRAPHICS);
	return 0;
}

/* -------------------------------------------------------------------- main */

int main(void)
{
	const char *preview = getenv("PACMAN_PREVIEW");
	struct cpustat prev[MAX_CPUS] = { 0 }, cur[MAX_CPUS];
	double load[MAX_CPUS] = { 0 };
	const char *part[MAX_CPUS];
	struct utsname un;
	int ncpu, frame = 0;

	if (getpid() == 1)
		early_mounts();

	if (preview) {
		W = 1080;
		H = 2412;
		pitch_px = W;
		fb_mem = calloc((size_t)W * H, 4);
	} else if (open_fb()) {
		fprintf(stderr, "pacman-dash: no usable /dev/fb0\n");
		for (;;)
			pause();	/* PID 1 must not exit */
	}
	buf = calloc((size_t)W * H, 4);

	uname(&un);
	read_cpu_parts(part, MAX_CPUS);
	ncpu = read_cpustat(prev, MAX_CPUS);
	if (ncpu <= 0)
		ncpu = 1;
	find_thermal_zones();

	for (;; frame++) {
		char s[160];
		int y;

		while (waitpid(-1, NULL, WNOHANG) > 0)
			;	/* reap, we are init */

		if (read_cpustat(cur, MAX_CPUS) > 0)
			for (int c = 0; c < ncpu; c++) {
				unsigned long long db = cur[c].busy - prev[c].busy;
				unsigned long long dt = cur[c].total - prev[c].total;
				double v = dt ? (double)db / dt : 0;
				load[c] = load[c] * 0.5 + v * 0.5;	/* smooth a little */
				prev[c] = cur[c];
			}
		if (preview) {	/* fake an 8-core phone so the preview shows the real layout */
			ncpu = MAX_CPUS;
			for (int c = 0; c < ncpu; c++)
				part[c] = c < 6 ? "A510" : "A715";
		}
		if (preview)
			for (int c = 0; c < ncpu; c++)
				load[c] = c == 3 ? 0.97 : 0.04 + 0.03 * c;

		fill(0, 0, W, H, C_BG);

		/* header */
		y = 120;
		dots(60, y, 26, C_FG, "PHONE");
		dots(60, y + 230, 26, C_FG, "(2A)");
		disc(60 + 4 * 6 * 26 + 10, y + 230 + 6 * 26 + 13, 13, C_RED);
		y += 450;
		text(60, y, 3, C_DIM, "mainline Linux");
		y += 70;
		snprintf(s, sizeof(s), "%s %s", un.sysname, un.release);
		text(60, y, 3, C_FG, s);
		y += 60;
		snprintf(s, sizeof(s), "%s  -  %d cores", un.machine, ncpu);
		text(60, y, 3, C_DIM, s);

		/* uptime */
		double up = uptime_s();
		int hh = (int)up / 3600, mm = ((int)up / 60) % 60, ss = (int)up % 60;
		y += 110;
		text(60, y, 3, C_DIM, "UPTIME");
		y += 60;
		snprintf(s, sizeof(s), "%02d:%02d:%02d", hh, mm, ss);
		text(60, y, 9, C_FG, s);

		/* cpu bars */
		y += 190;
		text(60, y, 3, C_DIM, "CPU");
		text(630, y, 3, C_DIM, "LOAD");
		text(800, y, 3, C_DIM, "TEMP");
		y += 64;
		for (int c = 0; c < ncpu; c++, y += 64) {
			uint32_t col = load[c] > 0.8 ? C_RED : C_FG;
			snprintf(s, sizeof(s), "%d %s", c, part[c]);
			text(60, y, 3, C_DIM, s);
			bar(250, y + 8, 340, 32, load[c], col);
			snprintf(s, sizeof(s), "%3d%%", (int)(load[c] * 100 + 0.5));
			text(630, y, 3, C_FG, s);
			temp_text(800, y, 3, preview ? 37000 + 400 * c : read_temp(cpu_tz[c]));
		}
		text(60, y, 3, C_DIM, "GPU");
		temp_text(800, y, 3, preview ? 33000 : read_temp(gpu_tz));
		y += 64;

		/* memory */
		unsigned long long mt = meminfo("MemTotal"), ma = meminfo("MemAvailable");
		y += 50;
		text(60, y, 3, C_DIM, "MEMORY");
		y += 64;
		bar(60, y, W - 120, 32, mt ? (double)(mt - ma) / mt : 0, C_FG);
		y += 56;
		snprintf(s, sizeof(s), "%.2f / %.2f GB used", (mt - ma) / 1048576.0, mt / 1048576.0);
		text(60, y, 3, C_FG, s);

		/* load average */
		y += 110;
		text(60, y, 3, C_DIM, "LOAD AVERAGE");
		y += 60;
		loadavg(s, sizeof(s));
		text(60, y, 4, C_FG, s);

		/* liveness: a red dot circling, like a tiny loading ring */
		int cx = W / 2, cy = H - 210;
		for (int i = 0; i < 12; i++) {
			double a = i * M_PI / 6;
			disc(cx + (int)(60 * cos(a)), cy + (int)(60 * sin(a)), 6, C_TRACK);
		}
		double a = (frame % 12) * M_PI / 6;
		disc(cx + (int)(60 * cos(a)), cy + (int)(60 * sin(a)), 10, C_RED);
		text(cx - 4 * 3 * 13, H - 110, 3, C_DIM, "pacman-dash on fb0");

		present();

		if (preview) {
			FILE *f = fopen(preview, "wb");
			fprintf(f, "P6\n%d %d\n255\n", W, H);
			for (int i = 0; i < W * H; i++) {
				uint32_t p = fb_mem[i];
				fputc((p >> 16) & 0xff, f);
				fputc((p >> 8) & 0xff, f);
				fputc(p & 0xff, f);
			}
			fclose(f);
			return 0;
		}
		usleep(200000);	/* 5 fps */
	}
}
