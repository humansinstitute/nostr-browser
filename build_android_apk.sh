#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
APP_DIR="$REPO_DIR/app"

command -v flutter >/dev/null 2>&1 || {
  echo "flutter is required. Install Flutter, then rerun this script." >&2
  exit 1
}

echo "Fetching Flutter dependencies..."
(
  cd "$APP_DIR"
  flutter pub get
)

echo "Building Android debug APK..."
(
  cd "$APP_DIR"
  flutter build apk --debug --target-platform android-arm64
)

echo "APK:"
echo "  $APP_DIR/build/app/outputs/flutter-apk/app-debug.apk"
