#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PATH="/opt/homebrew/bin:$PATH"
export RUSTC="$(rustup which --toolchain 1.98.0 rustc)"
export IPHONEOS_DEPLOYMENT_TARGET=13.0
export RUSTDOC="$(rustup which --toolchain 1.98.0 rustdoc)"
# Build input is pinned independently of Android; never mutate Cargo's cache.
python3 "$ROOT/tools/ios/prepare_core.py"
TARGET_DIR="$ROOT/crates/wmapp-fips-ios/target"
OUT="$ROOT/app/ios/FipsCore"
mkdir -p "$OUT"
for triple in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; do
  rustup run 1.98.0 cargo build --locked --release --manifest-path "$ROOT/crates/wmapp-fips-ios/Cargo.toml" --target "$triple"
done
mkdir -p "$OUT/simulator"
lipo -create "$TARGET_DIR/aarch64-apple-ios-sim/release/libwmapp_fips_ios.a" "$TARGET_DIR/x86_64-apple-ios/release/libwmapp_fips_ios.a" -output "$OUT/simulator/libwmapp_fips_ios.a"
rm -rf "$OUT/WmFips.xcframework"
xcodebuild -create-xcframework \
  -library "$TARGET_DIR/aarch64-apple-ios/release/libwmapp_fips_ios.a" -headers "$ROOT/app/ios/FipsPacketTunnel" \
  -library "$OUT/simulator/libwmapp_fips_ios.a" -headers "$ROOT/app/ios/FipsPacketTunnel" \
  -output "$OUT/WmFips.xcframework"
