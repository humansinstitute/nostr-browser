#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

cd "${ROOT}/app"
flutter pub get
flutter build linux --release "$@"

echo "Linux WM-App bundles are below: ${ROOT}/app/build/linux/"
