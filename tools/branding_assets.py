#!/usr/bin/env python3
"""Reproduce approved Nostr Browser raster exports with ImageMagick 7; --check audits them."""
import argparse
import hashlib
import json
import plistlib
from pathlib import Path
import re
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MASTER = ROOT / 'app/assets/branding/wayfinder-hybrid-dark.png'
MASTER_SHA256 = 'af5c3fdcd25d922e1a35500ba6c413924c64e4719c220e078819bde6783f7ba3'
HISTORICAL = ROOT / 'app/assets/branding/wayfinder-hybrid.png'
HISTORICAL_SHA256 = '4d647569a15b0d20a8392b615fdaf2029dbdcec48342a2a874667cfc310a5cc2'
BACKGROUND = '#131014'
PRODUCT_NAME = 'Nostr Browser'
SHORT_NAME = 'NBrowser'
LAUNCH_BACKGROUND = 'red="0.07450980392" green="0.06274509804" blue="0.07843137255"'
EXPORTS = {}


def add(path, size, maskable=False):
    EXPORTS[path] = (size, maskable)


add('app/web/favicon.png', 32)
for size in (192, 512):
    add(f'app/web/icons/Icon-{size}.png', size)
    add(f'app/web/icons/Icon-maskable-{size}.png', size, True)
for suffix, size in [('', 60), ('@2x', 120), ('@3x', 180)]:
    add(f'app/ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage{suffix}.png', size)
for platform in ('macos', 'ios'):
    folder = f'app/{platform}/Runner/Assets.xcassets/AppIcon.appiconset'
    for entry in json.loads((ROOT / folder / 'Contents.json').read_text())['images']:
        size = round(float(entry['size'].split('x')[0]) * float(entry['scale'][:-1]))
        add(f"{folder}/{entry['filename']}", size)
for density, size in [('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192)]:
    add(f'app/android/app/src/main/res/mipmap-{density}/ic_launcher.png', size)


def render(path, size, maskable):
    # The full approved square is reduced to 70% for maskable exports. The
    # coloured mark then stays inside the central 80%-diameter safe circle.
    inner = round(size * .70) if maskable else size
    subprocess.run(['magick', str(MASTER), '-resize', f'{inner}x{inner}',
                    '-background', BACKGROUND, '-alpha', 'remove', '-alpha', 'off',
                    '-gravity', 'center', '-extent', f'{size}x{size}',
                    '-strip', 'PNG24:' + str(path)], check=True)


def check_product_names():
    for platform in ('ios', 'macos'):
        info = plistlib.loads((ROOT / f'app/{platform}/Runner/Info.plist').read_bytes())
        for key in ('CFBundleDisplayName', 'CFBundleName'):
            value = info.get(key)
            if value == '$(PRODUCT_NAME)':
                app_info = (ROOT / 'app/macos/Runner/Configs/AppInfo.xcconfig').read_text()
                value = re.search(r'^PRODUCT_NAME = (.+)$', app_info, re.M).group(1).strip()
            assert value == PRODUCT_NAME, (platform, key, value)
    pbxproj = (ROOT / 'app/ios/Runner.xcodeproj/project.pbxproj').read_text()
    assert 'INFOPLIST_KEY_CFBundleDisplayName' not in pbxproj, 'iOS build settings override display name'
    gradle = (ROOT / 'app/android/app/build.gradle.kts').read_text()
    labels = re.findall(r'manifestPlaceholders\["wingmanAppLabel"\] = (.+)', gradle)
    assert labels == [f'"{PRODUCT_NAME}"'], ('Android label', labels)
    manifest = json.loads((ROOT / 'app/web/manifest.json').read_text())
    assert manifest['name'] == PRODUCT_NAME, manifest['name']
    assert manifest['short_name'] == SHORT_NAME, manifest['short_name']
    html = (ROOT / 'app/web/index.html').read_text()
    assert f'<title>{PRODUCT_NAME}</title>' in html, 'Web title'
    assert f'name="apple-mobile-web-app-title" content="{PRODUCT_NAME}"' in html, 'Apple web-app title'
    print(f'Product name: {PRODUCT_NAME} (iOS, macOS, Android, web)')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Compare each export and audit dimensions and references without writing assets')
    args = parser.parse_args()
    assert hashlib.sha256(MASTER.read_bytes()).hexdigest() == MASTER_SHA256, 'Approved dark master changed'
    assert hashlib.sha256(HISTORICAL.read_bytes()).hexdigest() == HISTORICAL_SHA256, 'Historical white master changed'
    master_info = subprocess.check_output(['magick', 'identify', '-format', '%wx%h %[channels]', str(MASTER)], text=True)
    assert master_info.split()[:2] == ['1254x1254', 'srgb'], master_info
    launch = (ROOT / 'app/ios/Runner/Base.lproj/LaunchScreen.storyboard').read_text()
    assert LAUNCH_BACKGROUND in launch, 'iOS launch background'
    check_product_names()
    failures = []
    with tempfile.TemporaryDirectory(prefix='nbrowser-branding-') as temp:
        for relative, (size, maskable) in EXPORTS.items():
            target = ROOT / relative
            output = Path(temp) / 'export.png' if args.check else target
            output.parent.mkdir(parents=True, exist_ok=True)
            render(output, size, maskable)
            if args.check and (not target.exists() or output.read_bytes() != target.read_bytes()):
                failures.append(relative)
                continue
            data = target.read_bytes()
            assert data[:8] == b'\x89PNG\r\n\x1a\n', relative
            width, height, depth, colour = struct.unpack('>IIBB', data[16:26])
            assert (width, height, depth, colour) == (size, size, 8, 2), relative
            if maskable:
                pixels = subprocess.check_output(['magick', str(target), '-depth', '8', 'RGB:-'])
                coloured_count = 0
                for offset in range(0, len(pixels), 3):
                    red, green, blue = pixels[offset:offset+3]
                    coloured = (red < 180 and blue > red + 30) or (red > 180 and green < 200 and blue < 150)
                    if coloured:
                        coloured_count += 1
                        index = offset // 3
                        x, y = index % size, index // size
                        assert ((x + .5 - size / 2) ** 2 + (y + .5 - size / 2) ** 2) ** .5 <= size * .4, relative
                assert coloured_count > size * size * .05, (relative, 'Missing coloured artwork')
                assert tuple(pixels[:3]) == (19, 16, 20), (relative, 'Incorrect dark padding')
            print(f'{relative}: PNG RGB {size}x{size}' + (' maskable safe padding' if maskable else ''))
        manifest = json.loads((ROOT / 'app/web/manifest.json').read_text())
        assert manifest['background_color'] == BACKGROUND, 'Background'
        assert manifest['theme_color'] == BACKGROUND, 'Theme'
        assert len(manifest['icons']) == 4, 'Icon inventory'
        for icon in manifest['icons']:
            dims = subprocess.check_output(['magick', 'identify', '-format', '%wx%h', str(ROOT / 'app/web' / icon['src'])], text=True)
            assert dims == icon['sizes'], (icon, dims)
            assert icon['type'] == 'image/png', icon
            assert icon.get('purpose', 'any') == ('maskable' if 'maskable' in icon['src'] else 'any'), icon
        for platform in ('ios', 'macos'):
            folder = ROOT / f'app/{platform}/Runner/Assets.xcassets/AppIcon.appiconset'
            for entry in json.loads((folder / 'Contents.json').read_text())['images']:
                assert (folder / entry['filename']).exists()
    print('Master SHA256:', hashlib.sha256(MASTER.read_bytes()).hexdigest())
    if failures:
        raise SystemExit('Stale or missing exports: ' + ', '.join(failures))
    print(f'PASS: {len(EXPORTS)} PNG exports, manifest and Apple catalog references')


if __name__ == '__main__':
    main()
