# Nostr Browser branding assets

Nostr Browser uses the approved wayfinder hybrid: a purple compass and wing with an
orange direction marker on near-black. The approved dark source is retained unchanged at
`app/assets/branding/wayfinder-hybrid-dark.png` (1254 × 1254 RGB PNG).
Its SHA-256 is
`af5c3fdcd25d922e1a35500ba6c413924c64e4719c220e078819bde6783f7ba3`.
The historical white source remains byte-for-byte at
`app/assets/branding/wayfinder-hybrid.png`, SHA-256
`4d647569a15b0d20a8392b615fdaf2029dbdcec48342a2a874667cfc310a5cc2`.
The generator pins both hashes and fails if either master changes.
Exports resize or pad that approved image; they do not redraw the artwork.
`app/assets/branding/wingman-bird-source.png` is the legacy Wingman bird and
must not be used for Nostr Browser application icons.

Run from the repository root with Python 3 and ImageMagick 7 installed:

```sh
python3 tools/branding_assets.py
python3 tools/branding_assets.py --check
python3 -m unittest tools/tests/test_branding_assets.py
```

The checked export toolchain is ImageMagick 7.1.2-8 Q16-HDRI. Use the same
version for byte comparison; resampling differences between versions can
require reviewing and regenerating the exports.

The check verifies PNG signatures, RGB format and dimensions, manifest MIME
types and purposes, and that coloured maskable pixels stay inside the
80%-diameter safe circle. It regenerates exports in a temporary directory,
compares their bytes, and checks Apple asset catalog references.

| Surface | Assets |
| --- | --- |
| Flutter web | `favicon.png` 32; manifest 192 and 512 normal and maskable PNGs |
| Android launchers | 48, 72, 96, 144, 192 for mdpi through xxxhdpi |
| iOS | AppIcon catalog, including the 1024 App Store image; launch logo 60/120/180 |
| macOS | AppIcon catalog, 16 through 1024 |

Maskable exports place the complete approved square at 70% of the canvas width
and centre it on near-black `#131014`, matching the dark master’s corner.
The web manifest uses `#131014` for theme and background, and the iOS launch
canvas uses the same colour. All generated PNGs are opaque RGB.

## Product name

The application name is **Nostr Browser** on every platform: iOS
`CFBundleDisplayName` and `CFBundleName`, the macOS product name, the Android
launcher label (release and nightly), the web manifest `name`, page title and
Apple web-app title. Use **NBrowser** only for compact labels such as the
manifest `short_name`. Bundle identifiers, application IDs and executable names
keep their existing values. `tools/branding_assets.py --check` validates these
names alongside the icon exports.

The audit checks source assets and configuration, not OS launcher caches or
installed apps. After a build, compare the packaged `Info.plist` and compiled
icons with these sources.
