#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
APP_DIR="$REPO_DIR/app"
APP_BUNDLE="$APP_DIR/build/macos/Build/Products/Debug/Nostr Browser.app"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/wingman_app"
LOG_FILE="${TMPDIR:-/tmp}/wingman_app.log"
ENV_FILE="$REPO_DIR/.env.local"
GIT_REV="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "runapp.sh currently launches the macOS Flutter build only." >&2
  exit 1
fi

if [[ ! -x "$APP_EXECUTABLE" ]]; then
  echo "No built macOS app found at:" >&2
  echo "  $APP_BUNDLE" >&2
  echo >&2
  echo "Run ./build_runapp.sh first." >&2
  exit 1
fi

stop_existing_app() {
  local pids
  pids="$(pgrep -x wingman_app || true)"
  if [[ -z "$pids" ]]; then
    return
  fi

  echo "Stopping existing Nostr Browser process..."
  kill $pids 2>/dev/null || true
  for _ in {1..20}; do
    if ! pgrep -x wingman_app >/dev/null 2>&1; then
      return
    fi
    sleep 0.1
  done
  pkill -9 -x wingman_app 2>/dev/null || true
}

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

stop_existing_app

echo "Starting Nostr Browser..."
echo "Repo: $REPO_DIR"
echo "Rev:  $GIT_REV"
echo "Log:  $LOG_FILE"

(
  cd "$APP_DIR"
  export WMAPP_REPO_DIR="$REPO_DIR"
  nohup "$APP_EXECUTABLE" >>"$LOG_FILE" 2>&1 &
)

echo "Launched."
