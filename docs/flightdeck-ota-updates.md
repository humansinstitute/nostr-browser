# Verified Flight Deck OTA updates in WMAPP

WMAPP can download a newer Flight Deck web build while continuing to serve it
from `http://127.0.0.1:47831`. GitHub distributes artifacts; the WebView never
loads GitHub, Pages, or branch source as its application origin. The packaged
`assets/flightdeck/` build remains the bootstrap and final fallback.

The updater is a WMAPP/native-shell concern. It is intentionally independent of
Flight Deck's TowerSyncService, Dexie materialisation, and workspace data sync.

## Build configuration

OTA is disabled by default. A release build must opt in and pin the feed and all
hosts that an archive download may follow:

```bash
flutter build apk \
  --dart-define=WMAPP_FLIGHTDECK_OTA_ENABLED=true \
  --dart-define=WMAPP_FLIGHTDECK_FEED_URL=https://otherstuffai.github.io/wm-flightdeck/stable/manifest.json \
  --dart-define=WMAPP_FLIGHTDECK_ARCHIVE_HOSTS=otherstuffai.github.io,github.com,release-assets.githubusercontent.com \
  --dart-define=WMAPP_VERSION=0.1.2 \
  --dart-define=WMAPP_NATIVE_BRIDGE_VERSION=1
```

Keep packaged-only builds (including any distribution channel whose policy has
not approved downloaded web application code) on the default with OTA disabled.
The configured feed/archive URLs must use HTTPS with no credentials, query, or
fragment. Redirects must remain HTTPS and on the compiled allowlist; provider-
signed query parameters are accepted only after that allowlisted redirect and
are never persisted or shown in errors.

## Manifest contract

Schema 1 requires:

- `build_number`, `build_id`, `source_commit`, `built_at`, and `channel`;
- `archive.format` (`tar.gz`), immutable HTTPS `url`, `sha256`, and
  `size_bytes`;
- `compatibility.minimum_wmapp_version` and `minimum_native_bridge`;
- optional allowlisted HTTPS `release_notes_url`.

WMAPP rejects unknown schema versions, older/same builds, incompatible native
bridges/app versions, malformed values, unapproved hosts, and archives larger
than the compiled limits. SHA-256 is streamed while downloading. It detects
corruption but is not an independent signature: feed authenticity currently
depends on pinned HTTPS origins and GitHub repository authority. A future
signed-manifest schema should add a public-key-pinned signature without changing
TowerSyncService.

## Storage and activation

Files live below the platform application-support directory:

```text
flightdeck-updates/
  state.json                 atomic active/previous/available pointer
  state.json.previous        crash-recovery pointer when replacement needs it
  downloads/                 unique temporary downloads; cleaned after work
  staging/                   unique extraction roots; cleaned on startup/failure
  versions/
    build-<number>-<digest>/  immutable verified build plus wmapp-install.json
```

The download and expanded TAR are bounded. Extraction rejects malformed TAR
headers/checksums, absolute or backslash paths, `.`/`..` traversal, duplicate
case-insensitive paths, links, special entries, excessive entry count,
oversized files, and excessive total output. `index.html` must exist and be
non-empty.

The verified staging directory is renamed into `versions/` before the small
state pointer is atomically replaced. Pointer failure leaves the old active
build selected. Only active and previous downloaded versions are retained. The
loopback server selects the active verified root per request; without one it
serves Flutter assets exactly as before. An invalid active receipt/entry point
on the next launch restores the previous verified version, or packaged assets.
A loopback serve failure triggers the same rollback. The Status screen exposes
current, packaged, available, previous, failed, timestamps, sanitized error,
check/retry, apply, and rollback controls.

## Manual test procedure

Use a local HTTPS fixture/feed or a reviewed unpublished fixture with build
defines above; do not point a release build at arbitrary hosts.

1. Launch online. Confirm ordinary startup reaches packaged Flight Deck before
   a slow feed responds, then Status shows the asynchronous check.
2. Serve a manifest newer than the packaged build and a valid archive. Use
   **Status → Apply update** (or allow startup auto-apply), then confirm the
   Flight Deck tab reloads at the unchanged `127.0.0.1:47831` origin.
3. Go offline and relaunch. Confirm the verified downloaded build still loads.
4. Publish fixture manifests with a bad digest, wrong size, newer bridge/app
   minimum, and malformed JSON. Confirm the active build never changes and the
   Status error is concise.
5. Exercise traversal, absolute-path, symlink, excessive-entry, oversized-file,
   and expanded-size fixtures. Confirm no file appears outside `staging/` and
   staging/downloads are cleaned.
6. Interrupt the archive response. Confirm the current build remains active.
7. Apply two valid fixtures, corrupt/delete the active fixture's `index.html`,
   and relaunch. Confirm the previous verified build is selected.
8. Use **Roll back**, confirm the previous build becomes current, reload the
   Flight Deck tab, and verify signer requests still originate from the same
   loopback origin.

Automated validation:

```bash
cd app
flutter test test/flight_deck_update_manager_test.dart test/status_screen_test.dart
flutter test
flutter analyze
flutter build apk --debug
```

## Apple distribution policy

Apple's current App Review Guideline 2.5.2 says apps may not download/install/
execute code that introduces or changes app features. Downloaded Flight Deck
HTML/JavaScript may therefore be rejected if it changes reviewed functionality,
even though it stays inside WMAPP's container and uses WebKit. Treat App Store
OTA enablement as a release/legal review decision; keep App Store builds
packaged-only unless Apple approves the exact model. See
https://developer.apple.com/app-store/review/guidelines/#software-requirements.
