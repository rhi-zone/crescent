# Crescent branding assets

`crescent.svg` is the canonical icon — a placeholder waxing crescent, single
path, fill `#3b82f6`, transparent background, 256x256 viewBox. It is intended
to be readable at 16x16 and is the only icon installers currently ship.

Linux desktop integration installs the SVG directly under
`$XDG_DATA_HOME/icons/hicolor/scalable/apps/crescent.svg` per the freedesktop
icon spec; no rasterization is required.

Windows (`.ico`) and macOS (`.icns`) rasters are not committed yet. They will
land in a follow-up commit. To regenerate them locally:

```sh
# Per-size PNGs (used as inputs for .ico and .icns):
for s in 16 24 32 48 64 128 256 512; do
  rsvg-convert -w $s -h $s crescent.svg -o crescent-${s}.png
done

# Windows .ico (multi-resolution, 16/24/32/48/64/128/256):
icotool -c -o crescent.ico \
  crescent-16.png crescent-24.png crescent-32.png crescent-48.png \
  crescent-64.png crescent-128.png crescent-256.png

# macOS .icns (via iconutil, requires an .iconset directory):
mkdir crescent.iconset
cp crescent-16.png   crescent.iconset/icon_16x16.png
cp crescent-32.png   crescent.iconset/icon_16x16@2x.png
cp crescent-32.png   crescent.iconset/icon_32x32.png
cp crescent-64.png   crescent.iconset/icon_32x32@2x.png
cp crescent-128.png  crescent.iconset/icon_128x128.png
cp crescent-256.png  crescent.iconset/icon_128x128@2x.png
cp crescent-256.png  crescent.iconset/icon_256x256.png
cp crescent-512.png  crescent.iconset/icon_256x256@2x.png
cp crescent-512.png  crescent.iconset/icon_512x512.png
iconutil -c icns crescent.iconset
rm -rf crescent.iconset crescent-*.png
```

`rsvg-convert` (librsvg), `icotool` (icoutils), and `iconutil` (macOS, built
in) are not part of the crescent dev shell — these are one-time generation
tools, not runtime dependencies.

Output files expected by the installers when committed:

- `branding/crescent.ico` — Windows Start Menu shortcut icon
- `branding/crescent.icns` — macOS `.app` bundle icon
