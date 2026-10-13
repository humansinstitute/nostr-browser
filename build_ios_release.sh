#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
APP_DIR="$REPO_DIR/app"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "iOS builds require macOS." >&2
  exit 1
fi

command -v flutter >/dev/null 2>&1 || {
  echo "flutter is required. Install Flutter, then rerun this script." >&2
  exit 1
}

SIGNING_CONFIG="$(python3 "$REPO_DIR/tools/ios/configure_apple_signing.py")"
export XCODE_XCCONFIG_FILE="$SIGNING_CONFIG"

"$REPO_DIR/tools/ios/build_core.sh"

"$REPO_DIR/tools/update_flightdeck_bundle.sh"

echo "Fetching Flutter dependencies..."
(
  cd "$APP_DIR"
  flutter pub get
)

echo "Building a signed iOS release app for standalone device launch..."
(
  cd "$APP_DIR"
  flutter build ios --release
)

echo "Release app:"
echo "  $APP_DIR/build/ios/iphoneos/Runner.app"
