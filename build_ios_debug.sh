#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
APP_DIR="$REPO_DIR/app"
TARGET="${1:-device}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "iOS builds require macOS." >&2
  exit 1
fi

command -v flutter >/dev/null 2>&1 || {
  echo "flutter is required. Install Flutter, then rerun this script." >&2
  exit 1
}

"$REPO_DIR/tools/ios/build_core.sh"

"$REPO_DIR/tools/update_flightdeck_bundle.sh"

echo "Fetching Flutter dependencies..."
(
  cd "$APP_DIR"
  flutter pub get
)

case "$TARGET" in
  simulator)
    echo "Building iOS simulator debug app..."
    (
      cd "$APP_DIR"
      flutter build ios --simulator --debug
    )
    echo "Simulator app:"
    echo "  $APP_DIR/build/ios/iphonesimulator/Runner.app"
    ;;
  device)
    echo "Building iOS device debug app without codesigning..."
    (
      cd "$APP_DIR"
      flutter build ios --debug --no-codesign
    )
    echo "Device app:"
    echo "  $APP_DIR/build/ios/iphoneos/Runner.app"
    ;;
  *)
    echo "Usage: ./build_ios_debug.sh [device|simulator]" >&2
    exit 1
    ;;
esac
