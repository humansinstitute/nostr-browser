#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
TEMP_DIR="$(mktemp -d /tmp/wmapp-fips-config-test.XXXXXX)"
trap 'rm -rf "$TEMP_DIR"' EXIT

PACKAGE="$TEMP_DIR/fips-0.5.0-macos-arm64.pkg"
EXPANDED="$TEMP_DIR/package"
CONFIG="$TEMP_DIR/fips.yaml"
PLIST="$TEMP_DIR/com.fips.daemon.plist"
ATTESTATION="$TEMP_DIR/wingman-poc-runtime.json"

"$ROOT/tools/prepare_fips_macos.sh" --arch arm64 "$PACKAGE" >/dev/null
pkgutil --expand-full "$PACKAGE" "$EXPANDED"
DEFAULT_CONFIG="$EXPANDED/Payload/usr/local/etc/fips/fips.yaml.default"
test -f "$DEFAULT_CONFIG"
cp "$DEFAULT_CONFIG" "$CONFIG"
: > "$PLIST"

FIPS_CONFIG_PATH="$CONFIG" FIPS_LAUNCHD_PLIST="$PLIST" \
  FIPS_ATTESTATION_PATH="$ATTESTATION" FIPS_CONFIG_TEST=1 \
  sh "$ROOT/tools/configure_fips_wingman_poc.sh" >/dev/null

require_section_line() {
  sed -n "/$1/,/$2/p" "$CONFIG" | grep -Eq "$3"
}

grep -Eq '^    persistent: true$' "$CONFIG"
require_section_line '^    nostr:$' '^    lan:$' '^      enabled: true$'
require_section_line '^    nostr:$' '^    lan:$' '^      policy: open$'
require_section_line '^    nostr:$' '^    lan:$' '^      app: "wingman-fips-poc-v1"$'
require_section_line '^    nostr:$' '^    lan:$' '^      advertise: true$'
require_section_line '^    nostr:$' '^    lan:$' '^      share_local_candidates: true$'
require_section_line '^    lan:$' '^tun:$' '^      enabled: true$'
require_section_line '^    lan:$' '^tun:$' '^      scope: "wingman-fips-poc-v1"$'
require_section_line '^tun:$' '^dns:$' '^  enabled: true$'
require_section_line '^dns:$' '^transports:$' '^  enabled: true$'
require_section_line '^  udp:$' '^  tcp:$' '^    advertise_on_nostr: true$'
require_section_line '^  udp:$' '^  tcp:$' '^    accept_connections: true$'
require_section_line '^  udp:$' '^  tcp:$' '^    outbound_only: false$'
grep -Fq 'npub1qmc3cvfz0yu2hx96nq3gp55zdan2qclealn7xshgr448d3nh6lks7zel98' "$CONFIG"
grep -Fq '217.77.8.91:2121' "$CONFIG"
grep -Fq '"schema":2' "$ATTESTATION"
grep -Fq '"lanScope":"wingman-fips-poc-v1"' "$ATTESTATION"
grep -Fq '"nostrShareLocalCandidates":true' "$ATTESTATION"
grep -Fq '"dnsEnabled":true' "$ATTESTATION"
grep -Fq '"bootstrapPeerAddress":"217.77.8.91:2121"' "$ATTESTATION"
cmp "$DEFAULT_CONFIG" "$CONFIG.pre-wingman-poc"

# Reapplying the helper must preserve the identity backup and be idempotent.
cp "$CONFIG" "$TEMP_DIR/expected.yaml"
FIPS_CONFIG_PATH="$CONFIG" FIPS_LAUNCHD_PLIST="$PLIST" \
  FIPS_ATTESTATION_PATH="$ATTESTATION" FIPS_CONFIG_TEST=1 \
  sh "$ROOT/tools/configure_fips_wingman_poc.sh" >/dev/null
cmp "$TEMP_DIR/expected.yaml" "$CONFIG"
cmp "$DEFAULT_CONFIG" "$CONFIG.pre-wingman-poc"

echo "FIPS Wingman PoC config transform passed against upstream v0.5.0."
