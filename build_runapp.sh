#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
APP_DIR="$REPO_DIR/app"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "build_runapp.sh currently builds and launches the macOS Flutter app only." >&2
  exit 1
fi

command -v git >/dev/null 2>&1 || {
  echo "git is required." >&2
  exit 1
}

command -v flutter >/dev/null 2>&1 || {
  echo "flutter is required. Install Flutter, then rerun this script." >&2
  exit 1
}

echo "Updating repo..."
git -C "$REPO_DIR" pull --ff-only

if [[ "${WMAPP_SKIP_CLEAN:-0}" != "1" ]]; then
  echo "Cleaning Flutter build cache..."
  (
    cd "$APP_DIR"
    flutter clean
  )
fi

echo "Fetching Flutter dependencies..."
(
  cd "$APP_DIR"
  flutter pub get
)

echo "Building macOS debug app..."
(
  cd "$APP_DIR"
  flutter build macos --debug
)

"$REPO_DIR/runapp.sh"
