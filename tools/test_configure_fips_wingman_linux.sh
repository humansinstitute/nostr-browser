#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
TEMP_DIR="$(mktemp -d /tmp/wmapp-fips-linux-config-test.XXXXXX)"
trap 'rm -rf "$TEMP_DIR"' EXIT

RUNTIME="$TEMP_DIR/runtime"
CONFIG="$TEMP_DIR/fips.yaml"
UNIT="$TEMP_DIR/fips.service"
ATTESTATION="$TEMP_DIR/wingman-poc-runtime.json"

"$ROOT/tools/prepare_fips_linux.sh" --arch x86_64 "$RUNTIME" >/dev/null
cp "$RUNTIME/fips.yaml" "$CONFIG"
: > "$UNIT"

FIPS_CONFIG_PATH="$CONFIG" FIPS_SYSTEMD_UNIT="$UNIT" \
  FIPS_ATTESTATION_PATH="$ATTESTATION" FIPS_CONFIG_TEST=1 \
  sh "$ROOT/tools/configure_fips_wingman_linux.sh" >/dev/null

require_section_line() {
  sed -n "/$1/,/$2/p" "$CONFIG" | grep -Eq "$3"
}

grep -Eq '^    persistent: true$' "$CONFIG"
require_section_line '^    nostr:$' '^    lan:$' '^      enabled: true$'
require_section_line '^    nostr:$' '^    lan:$' '^      app: "wingman-fips-poc-v1"$'
require_section_line '^    nostr:$' '^    lan:$' '^      share_local_candidates: true$'
require_section_line '^    lan:$' '^tun:$' '^      scope: "wingman-fips-poc-v1"$'
require_section_line '^tun:$' '^dns:$' '^  enabled: true$'
require_section_line '^dns:$' '^transports:$' '^  enabled: true$'
grep -Fq 'npub1qmc3cvfz0yu2hx96nq3gp55zdan2qclealn7xshgr448d3nh6lks7zel98' "$CONFIG"
grep -Fq '217.77.8.91:2121' "$CONFIG"
grep -Fq '"schema":2' "$ATTESTATION"
cmp "$RUNTIME/fips.yaml" "$CONFIG.pre-wingman-poc"

cp "$CONFIG" "$TEMP_DIR/expected.yaml"
FIPS_CONFIG_PATH="$CONFIG" FIPS_SYSTEMD_UNIT="$UNIT" \
  FIPS_ATTESTATION_PATH="$ATTESTATION" FIPS_CONFIG_TEST=1 \
  sh "$ROOT/tools/configure_fips_wingman_linux.sh" >/dev/null
cmp "$TEMP_DIR/expected.yaml" "$CONFIG"
cmp "$RUNTIME/fips.yaml" "$CONFIG.pre-wingman-poc"

echo "FIPS Linux config transform passed against upstream v0.5.0."
