#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
APP_DIR="$ROOT/app"
DIST_DIR="${WMAPP_DIST_DIR:-$ROOT/dist/macos}"
VERSION="$(sed -n 's/^version: \([^+]*\).*/\1/p' "$APP_DIR/pubspec.yaml")"
APP_PATH="$APP_DIR/build/macos/Build/Products/Release/Nostr Browser.app"
ENTITLEMENTS="$APP_DIR/macos/Runner/Release.entitlements"
MODE=local
SIGN_IDENTITY=""
NOTARY_PROFILE="${MACOS_NOTARY_PROFILE:-}"

case "${1:-}" in
  ""|--local) MODE=local ;;
  --public) MODE=public ;;
  --ad-hoc) MODE=ad-hoc ;;
  *) printf 'usage: %s [--local|--public|--ad-hoc]\n' "$0" >&2; exit 2 ;;
esac

case "$MODE" in
  local)
    DMG_PATH="$DIST_DIR/NBrowser-$VERSION-macos-universal-local.dmg"
    SIGN_IDENTITY="${MACOS_LOCAL_SIGN_IDENTITY:-}"
    ;;
  public)
    DMG_PATH="$DIST_DIR/NBrowser-$VERSION-macos-universal.dmg"
    SIGN_IDENTITY="${MACOS_SIGN_IDENTITY:-}"
    ;;
  ad-hoc)
    DMG_PATH="$DIST_DIR/NBrowser-$VERSION-macos-universal-ad-hoc.dmg"
    ;;
esac

for tool in flutter codesign hdiutil pkgutil security spctl shasum; do
  command -v "$tool" >/dev/null 2>&1 || { printf '%s is required.\n' "$tool" >&2; exit 1; }
done

if [[ "$MODE" == local && -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)"
fi
if [[ "$MODE" == public && -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)"
fi
if [[ "$MODE" == local && -z "$SIGN_IDENTITY" ]]; then
  echo 'No local code-signing identity is available. Install an Apple Development or private code-signing identity, or set MACOS_LOCAL_SIGN_IDENTITY to its exact name or SHA-1 hash.' >&2
  exit 1
fi
if [[ "$MODE" == public && -z "$SIGN_IDENTITY" ]]; then
  echo 'No Developer ID Application identity is available for the public release mode.' >&2
  exit 1
fi
if [[ "$MODE" == public && -z "$NOTARY_PROFILE" ]]; then
  echo 'MACOS_NOTARY_PROFILE is required for a public release build.' >&2
  exit 1
fi
if [[ "$MODE" != public && -n "$NOTARY_PROFILE" ]]; then
  echo 'MACOS_NOTARY_PROFILE is only accepted with --public; local/private builds are never submitted to Apple.' >&2
  exit 1
fi

(cd "$APP_DIR" && flutter build macos --release)
[[ -d "$APP_PATH" ]] || { echo "Missing built app: $APP_PATH" >&2; exit 1; }

if [[ "$MODE" == public ]]; then
  MACOS_NOTARY_PROFILE="$NOTARY_PROFILE" "$ROOT/tools/sign_notarize_fips_macos.sh" \
    "$APP_PATH/Contents/Resources/FIPS"
  for package in "$APP_PATH"/Contents/Resources/FIPS/*.pkg; do
    pkgutil --check-signature "$package"
    xcrun stapler validate "$package"
  done
fi

if [[ "$MODE" == public ]]; then
  codesign --force --deep --strict --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP_PATH"
elif [[ "$MODE" == local ]]; then
  codesign --force --deep --strict --options runtime --timestamp=none \
    --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP_PATH"
else
  codesign --force --deep --strict --entitlements "$ENTITLEMENTS" --sign - "$APP_PATH"
fi
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

mkdir -p "$DIST_DIR"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/wmapp-dmg.XXXXXX")"
cleanup() { rm -rf -- "$STAGE"; }
trap cleanup EXIT INT TERM
cp -R "$APP_PATH" "$STAGE/Nostr Browser.app"
ln -s /Applications "$STAGE/Applications"
rm -f -- "$DMG_PATH"
hdiutil create -quiet -volname "Nostr Browser" -srcfolder "$STAGE" -format UDZO -ov "$DMG_PATH"

if [[ "$MODE" == public ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
  codesign --verify --verbose=2 "$DMG_PATH"
elif [[ "$MODE" == local ]]; then
  codesign --force --timestamp=none --sign "$SIGN_IDENTITY" "$DMG_PATH"
  codesign --verify --verbose=2 "$DMG_PATH"
fi
hdiutil verify "$DMG_PATH"

if [[ "$MODE" == public ]]; then
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  spctl --assess --type open --context context:primary-signature -vv "$DMG_PATH"
else
  printf 'Private %s build: Apple notarization intentionally skipped.\n' "$MODE" >&2
fi

shasum -a 256 "$DMG_PATH"
printf '%s\n' "$DMG_PATH"
