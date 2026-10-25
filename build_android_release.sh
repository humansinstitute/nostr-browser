#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
APP_DIR="$REPO_DIR/app"
DEFAULT_KEYSTORE="${XDG_CONFIG_HOME:-$HOME/.config}/wmapp/android-release.jks"
KEYCHAIN_SERVICE="${WMAPP_ANDROID_KEYCHAIN_SERVICE:-wmapp-android-release}"
KEYCHAIN_ACCOUNT="${WMAPP_ANDROID_KEYCHAIN_ACCOUNT:-wmapp}"

command -v flutter >/dev/null 2>&1 || {
  echo "flutter is required." >&2
  exit 1
}

export WMAPP_ANDROID_KEYSTORE="${WMAPP_ANDROID_KEYSTORE:-$DEFAULT_KEYSTORE}"
export WMAPP_ANDROID_KEY_ALIAS="${WMAPP_ANDROID_KEY_ALIAS:-wmapp}"

if [[ ! -f "$WMAPP_ANDROID_KEYSTORE" ]]; then
  echo "Release keystore not found: $WMAPP_ANDROID_KEYSTORE" >&2
  echo "Run tools/setup_android_release_signing.sh once, or set WMAPP_ANDROID_KEYSTORE." >&2
  exit 1
fi

if [[ -z "${WMAPP_ANDROID_STORE_PASSWORD:-}" ]]; then
  command -v security >/dev/null 2>&1 || {
    echo "Set WMAPP_ANDROID_STORE_PASSWORD; macOS Keychain is unavailable." >&2
    exit 1
  }
  WMAPP_ANDROID_STORE_PASSWORD="$(security find-generic-password -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" -w)"
  export WMAPP_ANDROID_STORE_PASSWORD
fi
export WMAPP_ANDROID_KEY_PASSWORD="${WMAPP_ANDROID_KEY_PASSWORD:-$WMAPP_ANDROID_STORE_PASSWORD}"

cleanup_passwords() {
  unset WMAPP_ANDROID_STORE_PASSWORD WMAPP_ANDROID_KEY_PASSWORD
}
trap cleanup_passwords EXIT

(
  cd "$APP_DIR"
  flutter pub get
  flutter analyze
  flutter test
  flutter build apk --release --target-platform android-arm64
)

APK_PATH="$APP_DIR/build/app/outputs/flutter-apk/app-release.apk"
[[ -f "$APK_PATH" ]] || {
  echo "Expected release APK was not created: $APK_PATH" >&2
  exit 1
}

echo "Release APK: $APK_PATH"
shasum -a 256 "$APK_PATH"
