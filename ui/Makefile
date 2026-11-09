# Static aarch64 programs for the phone's initramfs (see initramfs.list).
# Note: not "CC ?=" -- make predefines CC=cc, so ?= would build for the host.
CROSS   ?= aarch64-linux-gnu-
CFLAGS  ?= -O2 -Wall -Wextra

all: pacman-dash pacman-reboot

pacman-dash: pacman-dash.c font8x16.h
	$(CROSS)gcc $(CFLAGS) -static -o $@ pacman-dash.c -lm
	$(CROSS)strip $@

pacman-reboot: pacman-reboot.c
	$(CROSS)gcc $(CFLAGS) -static -o $@ pacman-reboot.c
	$(CROSS)strip $@

# PC preview: renders one frame to preview.png (needs python3-pillow or ImageMagick)
preview: pacman-dash.c font8x16.h
	gcc $(CFLAGS) -o dash-preview pacman-dash.c -lm
	PACMAN_PREVIEW=preview.ppm ./dash-preview
	-magick preview.ppm preview.png 2>/dev/null || python3 -c "from PIL import Image; Image.open('preview.ppm').save('preview.png')"

clean:
	rm -f pacman-dash pacman-reboot dash-preview preview.ppm preview.png
.PHONY: all preview clean
