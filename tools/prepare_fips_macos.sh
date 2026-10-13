#!/usr/bin/env bash
set -euo pipefail

VERSION="0.5.0"
RELEASE_BASE="https://github.com/jmcorgan/fips/releases/download/v${VERSION}"
CACHE_DIR="${FIPS_CACHE_DIR:-$(cd "$(dirname "$0")/.." && pwd)/app/macos/.fips-cache}"
if [ "${1:-}" = "--arch" ]; then
  ARCH="${2:?missing architecture}"
  OUTPUT_PATH="${3:?usage: prepare_fips_macos.sh [--arch arm64|x86_64] OUTPUT_PATH}"
else
  ARCH="$(uname -m)"
  OUTPUT_PATH="${1:?usage: prepare_fips_macos.sh [--arch arm64|x86_64] OUTPUT_PATH}"
fi

case "$ARCH" in
  arm64)
    SHA256="3c2252677725a30f4ef68f01935ca6741e57568854d3f71202f2fa90d7239052"
    ;;
  x86_64)
    SHA256="a7883c71039ff591880c38c2421b361103f2ecf20840a9bd496eda13cb3e24c0"
    ;;
  *)
    echo "Unsupported macOS architecture: $ARCH" >&2
    exit 1
    ;;
esac

ASSET="fips-${VERSION}-macos-${ARCH}.pkg"
CACHED_PACKAGE="${CACHE_DIR}/${ASSET}"
mkdir -p "$CACHE_DIR"

if [[ ! -f "$CACHED_PACKAGE" ]] || \
   [[ "$(shasum -a 256 "$CACHED_PACKAGE" | awk '{print $1}')" != "$SHA256" ]]; then
  TEMP_PACKAGE="$(mktemp "${CACHE_DIR}/.${ASSET}.XXXXXX")"
  trap 'rm -f "${TEMP_PACKAGE:-}"' EXIT
  curl --fail --location --retry 3 --output "$TEMP_PACKAGE" \
    "${RELEASE_BASE}/${ASSET}"
  ACTUAL_SHA256="$(shasum -a 256 "$TEMP_PACKAGE" | awk '{print $1}')"
  if [[ "$ACTUAL_SHA256" != "$SHA256" ]]; then
    echo "FIPS package checksum mismatch: expected $SHA256, got $ACTUAL_SHA256" >&2
    exit 1
  fi
  mv "$TEMP_PACKAGE" "$CACHED_PACKAGE"
  trap - EXIT
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"
cp "$CACHED_PACKAGE" "$OUTPUT_PATH"
chmod 644 "$OUTPUT_PATH"
echo "Bundled FIPS v${VERSION} ${ARCH}: ${OUTPUT_PATH}"
