#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
PROJECT="$ROOT/app/macos/Runner.xcodeproj/project.pbxproj"
DEBUG_ENTITLEMENTS="$ROOT/app/macos/Runner/DebugProfile.entitlements"
RELEASE_ENTITLEMENTS="$ROOT/app/macos/Runner/Release.entitlements"
PACKAGER="$ROOT/tools/build_macos_dmg.sh"

for config_id in \
  33CC10FC2044A3C60003C045 \
  338D0CEA231458BD00FA5F75 \
  33CC10FD2044A3C60003C045; do
  settings="$(awk -v id="$config_id" '
    index($0, id " /*") { active=1 }
    active { print }
    active && /name = (Debug|Profile|Release);/ { exit }
  ' "$PROJECT")"
  grep -q 'CODE_SIGN_IDENTITY = "-";' <<<"$settings"
  grep -q 'CODE_SIGN_STYLE = Manual;' <<<"$settings"
done

if ! /usr/libexec/PlistBuddy -c 'Print :com.apple.security.cs.allow-jit' \
  "$DEBUG_ENTITLEMENTS" 2>/dev/null | grep -qx true; then
  echo 'Debug/Profile must retain the Flutter JIT entitlement.' >&2
  exit 1
fi

for entitlement in \
  com.apple.security.app-sandbox \
  com.apple.security.network.client \
  com.apple.security.network.server \
  keychain-access-groups; do
  if /usr/libexec/PlistBuddy -c "Print :$entitlement" "$DEBUG_ENTITLEMENTS" >/dev/null 2>&1 || \
     /usr/libexec/PlistBuddy -c "Print :$entitlement" "$RELEASE_ENTITLEMENTS" >/dev/null 2>&1; then
    echo "Unneeded or provisioning-dependent entitlement present: $entitlement" >&2
    exit 1
  fi
done

grep -q 'MACOS_NOTARY_PROFILE is required for a public release build' "$PACKAGER"
grep -q 'No Developer ID Application identity is available for the public release mode' "$PACKAGER"
grep -q 'xcrun notarytool submit' "$PACKAGER"
grep -Eq 'codesign .*--sign - .*APP_PATH' "$PACKAGER"

echo 'macOS signing modes are explicitly separated.'
