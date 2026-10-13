#!/bin/bash
# macOS process evidence only: no VPN, device installation or service restart.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
export WM_FIPS_MEASURE_SECONDS="${WM_FIPS_MEASURE_SECONDS:-30}"
python3 -c 'import os; s=float(os.environ["WM_FIPS_MEASURE_SECONDS"]); assert 10 <= s <= 300, "duration must be 10...300 seconds"'
OUT="${1:-tmp/docs/handoffs/fips-measure-$(date +%Y%m%d-%H%M%S)}"
OUT="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve())' "$OUT")"
case "$OUT" in "$ROOT/tmp/docs/handoffs/"*) ;; *) echo 'Use a directory under tmp/docs/handoffs/.' >&2; exit 1 ;; esac
git check-ignore -q "$OUT/" || { echo 'Use a Git-ignored evidence directory.' >&2; exit 1; }
[[ -z "$(git ls-files -- "$OUT")" ]] || { echo 'Evidence must be untracked.' >&2; exit 1; }
[[ ! -e "$OUT" ]] || { echo 'Use a new directory to preserve prior evidence.' >&2; exit 1; }
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
export RUSTC="$(rustup which --toolchain 1.98.0 rustc)"
# Run prepare_core.py separately; never replace vendor sources during a build.
rustup run 1.98.0 cargo build --locked --release --manifest-path crates/wmapp-fips-ios/Cargo.toml > "$OUT/build.log" 2>&1
swiftc -import-objc-header app/ios/FipsPacketTunnel/FipsCore.h \
  app/ios/FipsPacketTunnel/FipsPacketLifecycle.swift tools/ios/smoke_packet_path.swift \
  crates/wmapp-fips-ios/target/release/libwmapp_fips_ios.a \
  -framework Security -framework SystemConfiguration -lc++ -lresolv \
  -o "$OUT/measure-packet-path" >> "$OUT/build.log" 2>&1
"$OUT/measure-packet-path" > "$OUT/phases.log" 2>&1 &
measure_pid=$!
traffic_pid=''
cleanup() {
  if [[ -n "$traffic_pid" ]]; then kill "$traffic_pid" 2>/dev/null || true; fi
  kill "$measure_pid" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Process summaries omit endpoints and include loopback and all core sockets.
# Timestamp individual cumulative snapshots; closed sockets can reset totals.
python3 tools/ios/measure_traffic.py "$measure_pid" \
  > "$OUT/traffic.csv" 2> "$OUT/traffic-errors.log" &
traffic_pid=$!
result=0
wait "$measure_pid" || result=$?
wait "$traffic_pid" || echo 'nettop failed; inspect traffic-errors.log before using traffic evidence.' >&2
traffic_pid=''
trap - EXIT INT TERM
cat "$OUT/phases.log"
echo "Evidence: $OUT (nettop availability/errors must be checked separately)"
exit "$result"
