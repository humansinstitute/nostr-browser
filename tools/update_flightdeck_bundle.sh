#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
FLIGHT_DECK_DIR="${FLIGHT_DECK_DIR:-}"
FLIGHT_DECK_REPOSITORY="https://github.com/OtherStuffAI/wm-flightdeck.git"
TEMP_BUILD_DIR=""

cleanup() {
  if [[ -n "$TEMP_BUILD_DIR" ]]; then
    rm -rf -- "$TEMP_BUILD_DIR"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
TARGET_DIR="$REPO_DIR/app/assets/flightdeck"
USE_EXISTING_DIST=false

if [[ "${1:-}" == "--print-source" ]]; then
  printf '%s\n' "${FLIGHT_DECK_DIR:-$FLIGHT_DECK_REPOSITORY}"
  exit 0
fi

if [[ "${1:-}" == "--use-existing-dist" ]]; then
  USE_EXISTING_DIST=true
elif [[ -n "${1:-}" ]]; then
  printf 'usage: %s [--print-source|--use-existing-dist]\n' "$0" >&2
  exit 2
fi

if [[ "$USE_EXISTING_DIST" == true && -z "$FLIGHT_DECK_DIR" ]]; then
  echo '--use-existing-dist requires FLIGHT_DECK_DIR pointing to a local checkout.' >&2
  exit 2
fi

if [[ "$USE_EXISTING_DIST" == false ]]; then
  for tool in git bun node rsync; do
    command -v "$tool" >/dev/null 2>&1 || {
      printf '%s is required to build and bundle Flight Deck.\n' "$tool" >&2
      exit 1
    }
  done
  if [[ -z "$FLIGHT_DECK_DIR" ]]; then
    TEMP_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wmapp-flightdeck.XXXXXX")"
    FLIGHT_DECK_DIR="$TEMP_BUILD_DIR/source"
    printf 'Downloading latest Flight Deck main from %s...\n' "$FLIGHT_DECK_REPOSITORY"
    git clone --depth 1 --single-branch --branch main -- "$FLIGHT_DECK_REPOSITORY" "$FLIGHT_DECK_DIR"
    printf 'Flight Deck fetched source commit: %s\n' "$(git -C "$FLIGHT_DECK_DIR" rev-parse HEAD)"
  fi
  [[ -f "$FLIGHT_DECK_DIR/package.json" ]] || {
    printf 'Flight Deck checkout missing at %s; set FLIGHT_DECK_DIR to its location.\n' "$FLIGHT_DECK_DIR" >&2
    exit 1
  }
  printf 'Building Flight Deck from %s...\n' "$FLIGHT_DECK_DIR"
  (
    cd "$FLIGHT_DECK_DIR"
    if [[ -n "$TEMP_BUILD_DIR" ]]; then
      # Keep downloaded dependencies and transient build files with the clone.
      export BUN_INSTALL_CACHE_DIR="$TEMP_BUILD_DIR/bun-cache"
      export npm_config_cache="$TEMP_BUILD_DIR/npm-cache"
      mkdir -p "$TEMP_BUILD_DIR/tmp"
      export TMPDIR="$TEMP_BUILD_DIR/tmp"
      : "${FLIGHT_DECK_PG_APP_NPUB:?Set the verified Flight Deck app identity}"
      export FLIGHT_DECK_PG_APP_NPUB
      # Source commits can include the next release notes before a build updates
      # .build-meta.json. Use the newer recorded number without inventing a release.
      FLIGHTDECK_BUILD_NUMBER="$(node -e '
        const meta = require("./.build-meta.json");
        if (!Number.isSafeInteger(meta.absoluteVersion) || meta.absoluteVersion < 1) process.exit(1);
        const manifest = require("./release-notes.json");
        if (!Array.isArray(manifest.releases)) throw new Error("Invalid Flight Deck release notes");
        const version = manifest.releases.reduce((latest, release) => {
          if (!Number.isSafeInteger(release.buildNumber) || release.buildNumber < 1) {
            throw new Error("Invalid Flight Deck release build number");
          }
          return Math.max(latest, release.buildNumber);
        }, meta.absoluteVersion);
        console.log(version);
      ')"
      SOURCE_DATE_EPOCH="$(git log -1 --format=%ct)"
      FLIGHTDECK_BUILD_ID="wmapp-$(git rev-parse --short=12 HEAD)-$FLIGHTDECK_BUILD_NUMBER"
      export FLIGHTDECK_BUILD_NUMBER SOURCE_DATE_EPOCH FLIGHTDECK_BUILD_ID
      printf 'Flight Deck build %s, source %s\n' "$FLIGHTDECK_BUILD_NUMBER" "$FLIGHTDECK_BUILD_ID"
      bun install --frozen-lockfile
    fi
    bun run build
    bun run verify:dist
  )
fi

[[ -f "$FLIGHT_DECK_DIR/dist/version.json" ]] || {
  printf 'missing Flight Deck dist/version.json in %s\n' "$FLIGHT_DECK_DIR" >&2
  exit 1
}

mkdir -p "$TARGET_DIR"
rsync -a --delete "$FLIGHT_DECK_DIR/dist/" "$TARGET_DIR/"

echo "Bundled Flight Deck from $FLIGHT_DECK_DIR/dist"
echo "  $TARGET_DIR"
