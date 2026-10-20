#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="$REPO_DIR/tools/update_flightdeck_bundle.sh"

default_source="$(FLIGHT_DECK_DIR= "$SCRIPT" --print-source)"
expected_default="https://github.com/OtherStuffAI/wm-flightdeck.git"
[[ "$default_source" == "$expected_default" ]] || {
  printf 'expected default source %s, got %s\n' "$expected_default" "$default_source" >&2
  exit 1
}

override_source="/tmp/wmapp-flightdeck-source-override"
actual_override="$(FLIGHT_DECK_DIR="$override_source" "$SCRIPT" --print-source)"
[[ "$actual_override" == "$override_source" ]] || {
  printf 'expected override source %s, got %s\n' "$override_source" "$actual_override" >&2
  exit 1
}

printf 'update_flightdeck_bundle source resolution passed\n'

# Exercise the real updater and each platform entry point in an isolated repo.
# Native SDKs, signing, Git pulls and app launches must not run in this test.
fixture="$(mktemp -d "${TMPDIR:-/tmp}/wmapp-build-test.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/repo/tools" "$fixture/repo/app/assets/flightdeck" "$fixture/source/dist" "$fixture/bin"
mkdir -p "$fixture/repo/tools/ios"
# iOS helpers prepare the native core before bundling; keep SDK work isolated.
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture/repo/tools/ios/build_core.sh"
chmod +x "$fixture/repo/tools/ios/build_core.sh"
cp "$SCRIPT" "$fixture/repo/tools/"
cp "$REPO_DIR/tools/load_local_env.sh" "$fixture/repo/tools/"
cp "$REPO_DIR/tools/ios/configure_apple_signing.py" "$REPO_DIR/tools/ios/testflight_release.py" "$fixture/repo/tools/ios/"
mkdir -p "$fixture/repo/docs/deploy"
cp "$REPO_DIR/docs/deploy/"*ExportOptions.plist "$fixture/repo/docs/deploy/"
export WMAPP_APPLE_TEAM=A1B2C3D4E5
cp "$REPO_DIR"/build_*.sh "$fixture/repo/"
printf '{}\n' > "$fixture/source/package.json"
printf '{"absoluteVersion":1888}\n' > "$fixture/source/.build-meta.json"
printf '{"releases":[{"buildNumber":1888}]}\n' > "$fixture/source/release-notes.json"
printf 'stale\n' > "$fixture/repo/app/assets/flightdeck/stale.txt"
cat > "$fixture/bin/bun" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == 'install --frozen-lockfile' ]]; then
  [[ "$BUN_INSTALL_CACHE_DIR" == "$EXPECTED_TEMP_ROOT/"* ]]
  mkdir -p "$BUN_INSTALL_CACHE_DIR" "$npm_config_cache" node_modules
  [[ "${FAIL_INSTALL:-0}" != 1 ]] || exit 24
  exit 0
fi
if [[ "$*" == 'run verify:dist' ]]; then
  [[ "${FAIL_VERIFY:-0}" != 1 ]] || exit 25
  exit 0
fi
[[ "$*" == 'run build' ]]
[[ "$FLIGHT_DECK_PG_APP_NPUB" == "${EXPECTED_APP_NPUB:?}" ]]
if [[ -z "${FLIGHT_DECK_DIR:-}" ]]; then
  [[ "$FLIGHTDECK_BUILD_NUMBER" == "${EXPECTED_BUILD_NUMBER:-1888}" ]]
  [[ -n "$FLIGHT_DECK_PG_APP_NPUB" ]]
else
  [[ "$PWD" == "$FLIGHT_DECK_DIR" ]]
fi
printf 'flightdeck\n' >> "$BUILD_TEST_LOG"
[[ "${FAIL_FLIGHTDECK:-0}" != 1 ]] || exit 23
printf '{"buildNumber":%s}\n' "${FLIGHTDECK_BUILD_NUMBER:-1888}" > dist/version.json
STUB
cat > "$fixture/bin/flutter" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ -f assets/flightdeck/version.json ]]
[[ ! -f assets/flightdeck/stale.txt ]]
[[ "$(head -n 1 "$BUILD_TEST_LOG")" == flightdeck ]]
printf 'flutter %s\n' "$*" >> "$BUILD_TEST_LOG"
# Stop before any post-build launch, artifact or signing inspection.
if [[ "${1:-}" == build ]]; then exit 42; fi
STUB
cat > "$fixture/bin/uname" <<'STUB'
#!/usr/bin/env bash
printf 'Darwin\n'
STUB
cat > "$fixture/bin/git" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == clone ]]; then
  [[ "$*" == *'--depth 1 --single-branch --branch main -- https://github.com/OtherStuffAI/wm-flightdeck.git'* ]]
  destination="${!#}"
  mkdir -p "$destination"
  [[ "${FAIL_CLONE:-0}" != 1 ]] || exit 26
  cp -R "$TEST_SOURCE/." "$destination/"
elif [[ "${1:-}" == log ]]; then
  printf '1788753600\n'
elif [[ "${1:-}" == rev-parse || "${3:-}" == rev-parse ]]; then
  printf '123456abcdef\n'
fi
STUB
chmod +x "$fixture/bin/"*
export PATH="$fixture/bin:$PATH"
export FLIGHT_DECK_DIR="$fixture/source"
export BUILD_TEST_LOG="$fixture/events"
export EXPECTED_APP_NPUB="npub1hd37reqgfcnz3pvzj4grknd2nkzc94p9ercmunrxx22razr2rfxsw6dns5"
export WMAPP_ANDROID_KEYSTORE="$fixture/test-keystore"
export WMAPP_ANDROID_STORE_PASSWORD=test-only
export WMAPP_ANDROID_KEY_PASSWORD=test-only
touch "$WMAPP_ANDROID_KEYSTORE"

for script in "$fixture/repo"/build_*.sh; do
  : > "$BUILD_TEST_LOG"
  status=0
  bash "$script" > "$fixture/output" 2>&1 || status=$?
  if [[ "$status" != 42 ]] || ! rg -q '^flutter build ' "$BUILD_TEST_LOG"; then
    cat "$fixture/output" >&2
    printf 'platform build did not refresh Flight Deck first: %s (exit %s)\n' "$script" "$status" >&2
    exit 1
  fi

  : > "$BUILD_TEST_LOG"
  status=0
  FAIL_FLIGHTDECK=1 bash "$script" > "$fixture/output" 2>&1 || status=$?
  if [[ "$status" != 23 ]] || rg -q '^flutter ' "$BUILD_TEST_LOG"; then
    cat "$fixture/output" >&2
    printf 'platform build continued after Flight Deck failed: %s\n' "$script" >&2
    exit 1
  fi
done

# Simulator follows the same preparation path as an iOS device build.
: > "$BUILD_TEST_LOG"
status=0
bash "$fixture/repo/build_ios_debug.sh" simulator > "$fixture/output" 2>&1 || status=$?
[[ "$status" == 42 ]]
rg -q '^flutter build ios --simulator --debug$' "$BUILD_TEST_LOG"

# Manual reuse must not invoke the source build.
: > "$BUILD_TEST_LOG"
"$fixture/repo/tools/update_flightdeck_bundle.sh" --use-existing-dist
[[ ! -s "$BUILD_TEST_LOG" ]]

printf 'All seven platform helpers refresh Flight Deck and stop on build failure; simulator and manual reuse passed\n'

# Repository-local overrides load before the embedded build. An explicit process
# environment wins over the same names in .env.local.
alternate_npub="npub1vf3h0rmlrr0x6pjc68jcrk5p2zsfzl3f9zwcppcdn8386npdlxgqmam99v"
cat > "$fixture/repo/.env.local" <<EOF
export FLIGHT_DECK_DIR="$fixture/source"
export FLIGHT_DECK_PG_APP_NPUB="$alternate_npub"
EOF
unset FLIGHT_DECK_DIR FLIGHT_DECK_PG_APP_NPUB
export EXPECTED_APP_NPUB="$alternate_npub"
: > "$BUILD_TEST_LOG"
"$fixture/repo/tools/update_flightdeck_bundle.sh"
[[ "$(cat "$BUILD_TEST_LOG")" == 'flightdeck' ]]

cat > "$fixture/repo/.env.local" <<EOF
export FLIGHT_DECK_DIR="/local-env-must-not-win"
export FLIGHT_DECK_PG_APP_NPUB="$alternate_npub"
EOF
export EXPECTED_APP_NPUB="npub1hd37reqgfcnz3pvzj4grknd2nkzc94p9ercmunrxx22razr2rfxsw6dns5"
: > "$BUILD_TEST_LOG"
FLIGHT_DECK_DIR="$fixture/source" \
  FLIGHT_DECK_PG_APP_NPUB="$EXPECTED_APP_NPUB" \
  "$fixture/repo/tools/update_flightdeck_bundle.sh"
[[ "$(cat "$BUILD_TEST_LOG")" == 'flightdeck' ]]
rm "$fixture/repo/.env.local"
printf '.env.local loading and explicit process-environment precedence passed\n'

# Explicit malformed overrides fail closed before source build or download.
: > "$BUILD_TEST_LOG"
status=0
FLIGHT_DECK_DIR="$fixture/source" FLIGHT_DECK_PG_APP_NPUB=not-an-npub \
  "$fixture/repo/tools/update_flightdeck_bundle.sh" > "$fixture/output" 2>&1 || status=$?
[[ "$status" == 2 && ! -s "$BUILD_TEST_LOG" ]]
rg -q 'must be a valid npub' "$fixture/output"
printf 'Malformed Flight Deck app npub fails closed\n'

# Default GitHub path: cleanup and preserve old assets on every failure stage.
export TEST_SOURCE="$fixture/source"
export EXPECTED_TEMP_ROOT="$fixture/downloads"
mkdir -p "$EXPECTED_TEMP_ROOT"
unset FLIGHT_DECK_DIR FLIGHT_DECK_PG_APP_NPUB
for failure in none FAIL_CLONE FAIL_INSTALL FAIL_FLIGHTDECK FAIL_VERIFY; do
  : > "$BUILD_TEST_LOG"
  printf 'preserve\n' > "$fixture/repo/app/assets/flightdeck/sentinel"
  status=0
  if [[ "$failure" == none ]]; then
    TMPDIR="$EXPECTED_TEMP_ROOT" "$fixture/repo/tools/update_flightdeck_bundle.sh" > "$fixture/output" 2>&1 || status=$?
    [[ "$status" == 0 && ! -f "$fixture/repo/app/assets/flightdeck/sentinel" ]] || {
      cat "$fixture/output" >&2; exit 1;
    }
  else
    env "$failure=1" TMPDIR="$EXPECTED_TEMP_ROOT" "$fixture/repo/tools/update_flightdeck_bundle.sh" > "$fixture/output" 2>&1 || status=$?
    [[ "$status" != 0 && -f "$fixture/repo/app/assets/flightdeck/sentinel" ]] || {
      cat "$fixture/output" >&2; exit 1;
    }
  fi
  [[ -z "$(ls -A "$EXPECTED_TEMP_ROOT")" ]] || {
    echo "Temporary downloads remained after $failure" >&2; exit 1;
  }
done
[[ -f "$TEST_SOURCE/package.json" ]]
printf 'GitHub source, dependency install, version preservation and cleanup checks passed\n'

# A source release can be committed before its build metadata is incremented.
# Also preserve a later metadata number when the last user-facing note is older.
for versions in '1891 1892 1892' '1892 1892 1892' '1893 1892 1893'; do
  read -r metadata_version notes_version expected_version <<< "$versions"
  printf '{"absoluteVersion":%s}\n' "$metadata_version" > "$TEST_SOURCE/.build-meta.json"
  printf '{"releases":[{"buildNumber":%s}]}\n' "$notes_version" > "$TEST_SOURCE/release-notes.json"
  EXPECTED_BUILD_NUMBER="$expected_version" TMPDIR="$EXPECTED_TEMP_ROOT" "$fixture/repo/tools/update_flightdeck_bundle.sh" > "$fixture/output" 2>&1 || {
    cat "$fixture/output" >&2; exit 1;
  }
  [[ "$(node -p "require(process.argv[1]).buildNumber" "$fixture/repo/app/assets/flightdeck/version.json")" == "$expected_version" ]]
  [[ -z "$(ls -A "$EXPECTED_TEMP_ROOT")" ]]
done
printf 'Release notes ahead of, equal to, and behind build metadata passed\n'
