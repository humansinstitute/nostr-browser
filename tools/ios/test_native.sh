#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
export RUSTC="$(rustup which --toolchain 1.98.0 rustc)"
# Prepare once before invoking this script; do not regenerate during cross-builds.
rustup run 1.98.0 cargo test --locked --manifest-path crates/wmapp-fips-ios/Cargo.toml --lib
rustup run 1.98.0 cargo build --locked --manifest-path crates/wmapp-fips-ios/Cargo.toml
swiftc app/ios/FipsPacketTunnel/FipsTunnelSettings.swift tools/ios/test_settings.swift -o build/ios-fips/test-settings
build/ios-fips/test-settings
swiftc app/ios/FipsPacketTunnel/FipsPacketLifecycle.swift tools/ios/test_lifecycle.swift -o build/ios-fips/test-lifecycle
build/ios-fips/test-lifecycle
swiftc -import-objc-header app/ios/FipsPacketTunnel/FipsCore.h \
  app/ios/FipsPacketTunnel/FipsPacketLifecycle.swift tools/ios/smoke_packet_path.swift \
  crates/wmapp-fips-ios/target/debug/libwmapp_fips_ios.a \
  -framework Security -framework SystemConfiguration -lc++ -lresolv -o build/ios-fips/smoke-packet-path
build/ios-fips/smoke-packet-path
