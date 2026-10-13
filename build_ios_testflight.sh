#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
APP_DIR="$REPO_DIR/app"

# Release orchestration supplies explicit versions without editing pubspec.yaml.
# Keep this helper export-only and reject unrelated Flutter options.
EXPORT_OPTIONS="$REPO_DIR/docs/deploy/TestFlightExportOptions.plist"
FLUTTER_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --build-name=*|--build-number=*) FLUTTER_ARGS+=("$arg") ;;
    --external) EXPORT_OPTIONS="$REPO_DIR/docs/deploy/TestFlightExternalExportOptions.plist" ;;
    *) echo "Supported options: --build-name=x.y.z --build-number=N [--external]" >&2; exit 1 ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "iOS archives require macOS and Xcode." >&2
  exit 1
fi
command -v flutter >/dev/null 2>&1 || {
  echo "flutter is required." >&2
  exit 1
}

SIGNING_CONFIG="$(python3 "$REPO_DIR/tools/ios/configure_apple_signing.py")"
export XCODE_XCCONFIG_FILE="$SIGNING_CONFIG"

"$REPO_DIR/tools/ios/build_core.sh"

"$REPO_DIR/tools/update_flightdeck_bundle.sh"

if [[ "$EXPORT_OPTIONS" == *External* ]]; then MODE=external; else MODE=internal; fi
EXPORT_OPTIONS="$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); import testflight_release as r; print(r.options(sys.argv[2]))' "$REPO_DIR/tools/ios" "$MODE")"

# Flutter can exit successfully after archiving even when IPA export fails.
# Use a timestamp marker so a stale IPA cannot be reported as this build.
mkdir -p "$APP_DIR/build/ios"
MARKER="$(mktemp "$APP_DIR/build/ios/.testflight-build.XXXXXX")"
trap 'rm -f "$MARKER"' EXIT
(
  cd "$APP_DIR"
  flutter build ipa --release \
    --export-options-plist="$EXPORT_OPTIONS" ${FLUTTER_ARGS[@]+"${FLUTTER_ARGS[@]}"}
)
IPA="$(find "$APP_DIR/build/ios/ipa" -maxdepth 1 -name '*.ipa' -newer "$MARKER" -print -quit 2>/dev/null || true)"
if [[ -z "$IPA" ]]; then
  echo "No new TestFlight IPA was exported. Inspect the signing errors above." >&2
  echo "Any archive in $APP_DIR/build/ios/archive still requires distribution export." >&2
  echo "CLI No Accounts does not establish GUI sign-out. Check Xcode Settings → Apple Accounts for team <existing-apple-team>; use Organizer Export with the existing account if CLI resolution fails." >&2
  echo "For a visible codesign Keychain prompt, enter the password only in that dialog and choose Allow; see docs/deploy/testflight.md." >&2
  exit 1
fi
echo "Exported IPA: $IPA"
echo "Local export only. Upload and verify App Store Connect processing before reporting TestFlight availability."
