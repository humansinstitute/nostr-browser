#!/bin/sh
set -eu
DRIVE_REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export PATH="$HOME/.cargo/bin:$PATH"
cargo build --manifest-path "$DRIVE_REPO/Cargo.toml" -p wmapp-drive-fs --release
mkdir -p "$1"
cp "$DRIVE_REPO/target/release/wmapp-drive-fs" "$1/wmapp-drive-fs"
if [ "$(uname -s)" = Darwin ]; then codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$1/wmapp-drive-fs"; fi
