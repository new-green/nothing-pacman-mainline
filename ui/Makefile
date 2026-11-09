# Static aarch64 build of the dashboard that runs as /init on the phone.
CC      ?= aarch64-linux-gnu-gcc
CFLAGS  ?= -O2 -Wall -Wextra

pacman-dash: pacman-dash.c font8x16.h
	$(CC) $(CFLAGS) -static -o $@ pacman-dash.c -lm
	aarch64-linux-gnu-strip $@

# PC preview: renders one frame to preview.png (needs python3-pillow or ImageMagick)
preview: pacman-dash.c font8x16.h
	gcc $(CFLAGS) -o dash-preview pacman-dash.c -lm
	PACMAN_PREVIEW=preview.ppm ./dash-preview
	-magick preview.ppm preview.png 2>/dev/null || python3 -c "from PIL import Image; Image.open('preview.ppm').save('preview.png')"

clean:
	rm -f pacman-dash dash-preview preview.ppm preview.png
.PHONY: preview clean
