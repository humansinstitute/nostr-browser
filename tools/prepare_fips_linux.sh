#!/usr/bin/env bash
set -euo pipefail

VERSION="0.5.0"
RELEASE_BASE="https://github.com/jmcorgan/fips/releases/download/v${VERSION}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE_DIR="${FIPS_CACHE_DIR:-${ROOT}/app/linux/.fips-cache}"

if [[ "${1:-}" == "--arch" ]]; then
  ARCH="${2:?missing architecture}"
  OUTPUT_DIR="${3:?usage: prepare_fips_linux.sh [--arch x86_64|aarch64] OUTPUT_DIR}"
else
  ARCH="$(uname -m)"
  OUTPUT_DIR="${1:?usage: prepare_fips_linux.sh [--arch x86_64|aarch64] OUTPUT_DIR}"
fi

case "${ARCH}" in
  amd64|x86_64)
    FIPS_ARCH="x86_64"
    SHA256="a57240b70d8e0940ba5d962b0b9881cadd2befb43b75991e435d74243cbd7b27"
    ;;
  arm64|aarch64)
    FIPS_ARCH="aarch64"
    SHA256="c0e00bd8e9dc0ca01cbd6992da5d3944530a6a18df4e2d36c073b3913488d40f"
    ;;
  *)
    echo "Unsupported Linux architecture: ${ARCH}" >&2
    exit 1
    ;;
esac

ASSET="fips-${VERSION}-linux-${FIPS_ARCH}.tar.gz"
CACHED_ARCHIVE="${CACHE_DIR}/${ASSET}"

checksum() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

mkdir -p "${CACHE_DIR}"
if [[ ! -f "${CACHED_ARCHIVE}" ]] || [[ "$(checksum "${CACHED_ARCHIVE}")" != "${SHA256}" ]]; then
  TEMP_ARCHIVE="$(mktemp "${CACHE_DIR}/.${ASSET}.XXXXXX")"
  trap 'rm -f "${TEMP_ARCHIVE:-}"' EXIT
  curl --fail --location --retry 3 --output "${TEMP_ARCHIVE}" \
    "${RELEASE_BASE}/${ASSET}"
  ACTUAL_SHA256="$(checksum "${TEMP_ARCHIVE}")"
  if [[ "${ACTUAL_SHA256}" != "${SHA256}" ]]; then
    echo "FIPS archive checksum mismatch: expected ${SHA256}, got ${ACTUAL_SHA256}" >&2
    exit 1
  fi
  mv "${TEMP_ARCHIVE}" "${CACHED_ARCHIVE}"
  trap - EXIT
fi

EXTRACT_DIR="$(mktemp -d "${CACHE_DIR}/.extract.${FIPS_ARCH}.XXXXXX")"
trap 'rm -rf "${EXTRACT_DIR:-}"' EXIT
tar -xzf "${CACHED_ARCHIVE}" -C "${EXTRACT_DIR}"
SOURCE_DIR="${EXTRACT_DIR}/fips-${VERSION}-linux-${FIPS_ARCH}"

REQUIRED_FILES=(
  fips fipsctl fipstop fips-gateway
  fips-dns-setup fips-dns-teardown
  fips.service fips-dns.service fips-firewall.service fips-gateway.service
  fips.yaml fips.nft hosts install.sh uninstall.sh README.install.md
)
for file in "${REQUIRED_FILES[@]}"; do
  if [[ ! -f "${SOURCE_DIR}/${file}" ]]; then
    echo "FIPS release archive is missing ${file}" >&2
    exit 1
  fi
done

mkdir -p "${OUTPUT_DIR}"
for file in "${REQUIRED_FILES[@]}"; do
  cp "${SOURCE_DIR}/${file}" "${OUTPUT_DIR}/${file}"
done
chmod 0755 \
  "${OUTPUT_DIR}/fips" \
  "${OUTPUT_DIR}/fipsctl" \
  "${OUTPUT_DIR}/fipstop" \
  "${OUTPUT_DIR}/fips-gateway" \
  "${OUTPUT_DIR}/fips-dns-setup" \
  "${OUTPUT_DIR}/fips-dns-teardown" \
  "${OUTPUT_DIR}/install.sh" \
  "${OUTPUT_DIR}/uninstall.sh"

echo "Bundled FIPS v${VERSION} Linux ${FIPS_ARCH}: ${OUTPUT_DIR}"
