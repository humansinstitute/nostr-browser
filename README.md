# Nostr Browser

The launcher and iPhone Home Screen label is **NBrowser**. The canonical checkout
is `~/code/nbrowser`, with source at
[humansinstitute/nostr-browser](https://github.com/humansinstitute/nostr-browser).
Existing bundle IDs and signing remain unchanged so updates retain app data.

Nostr Browser is the planned native edge client for Wingman Be Free.

The initial product combines:

- Wingman Drive: a desktop/mobile file surface backed by Tower HTTP storage.
- Nostr Browser: an embedded browser for Flight Deck and WApps with native Nostr signing.
- Wingman Signer: local per-device Nostr key custody for NIP-98 and approved app signing.

Tower remains the source of truth for workspace identity, scopes, channels, groups, file metadata, and object storage.

## Repository Checkout

The original WM App source remains at `https://github.com/OtherStuffAI/wm-app`.
Nostr Browser development uses the independent `~/code/nbrowser` checkout.

Every root `build_*.sh` script downloads the latest `main` from
`https://github.com/OtherStuffAI/wm-flightdeck.git`, installs its locked
dependencies, builds and verifies Flight Deck, then bundles it before building
Flutter. The bundled output in `app/assets/flightdeck` is generated locally and
ignored by Git; it should not be committed to this repository. Git, Bun,
Node.js, rsync and network access are required; private repository access uses
your normal Git credentials.

The clone, dependencies and temporary dependency caches are removed on success,
failure or interruption. Only the bundled output in `app/assets/flightdeck`
is retained. Refreshes preserve the committed Flight Deck version number and log
the source commit. The public Flight Deck app identifier is supplied by default;
`FLIGHT_DECK_PG_APP_NPUB` can override it. A download, install, build or verification
failure stops the app build instead of silently using an old bundle.

For local development, `FLIGHT_DECK_DIR=/path/to/flightdeck ./build_runapp.sh`
builds that checkout instead, using its existing dependencies and configuration.
This explicit override is never deleted or pulled. To manually reuse its built
assets, run `FLIGHT_DECK_DIR=/path/to/flightdeck ./tools/update_flightdeck_bundle.sh --use-existing-dist`.

`runapp.sh` only launches an existing app. Direct `flutter build` commands still
use whichever assets are already bundled.

The former `~/code/wingmanbefree/wm-app` checkout is a legacy checkpoint and
should not be used for new changes.

## Current Status

Phase 1 contracts and the Phase 2 headless native core are complete.

Latest package: `WP-02-05: Sync CLI And Local Control API`.

## Native Core

The first Rust core crate lives at `crates/wmapp-core`.

Useful commands:

```bash
cargo test
cargo run --bin wmapp-core -- status
cargo run --bin wmapp-core -- device generate --show-secret
cargo run --bin wmapp-core -- sign-nip98 --secret <hex-or-nsec> --method POST --url https://tower.example/api --body '{"hello":"wingman"}'
```

Tower read commands use NIP-98 signing. They accept flags or environment:

```bash
export TOWER_URL="http://127.0.0.1:3100"
export FLIGHTDECK_APP_NPUB="<verified-app-npub>"
export WINGMAN_NSEC="<hex-or-nsec-device-or-agent-key>"

cargo run --bin wmapp-core -- status --workspace-id <workspace-id>
cargo run --bin wmapp-core -- list-files --workspace-id <workspace-id> --channel-id <channel-id>
cargo run --bin wmapp-core -- sync --once --workspace-id <workspace-id> --channel-id <channel-id>
cargo run --bin wmapp-core -- list-items --workspace-id <workspace-id>
cargo run --bin wmapp-core -- cat --workspace-id <workspace-id> <file-id> --output /tmp/file.out
cargo run --bin wmapp-core -- pin <file-id>
cargo run --bin wmapp-core -- evict <file-id> --force
cargo run --bin wmapp-core -- mount --dry-run --workspace-id <workspace-id> --mountpoint ~/FlightDeck
cargo run --bin wmapp-core -- mount --workspace-id <workspace-id> --mountpoint ~/FlightDeck
```

The `mount --dry-run` command prints the read-only Drive tree that the FUSE/macFUSE adapter exposes. The non-dry-run mount is a foreground read-only kernel mount: keep the process running and unmount the mountpoint from another shell. Mounted file reads use the local cache first and hydrate from Tower on cache miss when Tower auth is configured. On macOS the CLI preflights macFUSE and fails clearly if the kernel device cannot be loaded or approved.

## Flutter Shell

Right-click a browser tab to choose its colour or set a prefix. Enter `WORK`
to display `WORK: Page title`; the page title continues to update as you browse.
Choose **Default colour** or save an empty prefix to remove the customization.
These settings are saved with your tabs for the current identity.

The Flutter shell lives at `app/`. It defines setup, Drive, browser, and status screens plus a `NativeCoreBridge` local-process bridge to the existing Rust core.

The current desktop build can register a device through Tower, validate a configured channel, trigger one-shot sync, list local Drive metadata, and inject a `window.nostr` bridge into WebView pages. Device key generation/import, NIP-07 `signEvent`, and NIP-98 signing are implemented in Dart so they work in the Flutter app on desktop and mobile without shelling out to Rust.

## Where your Nostr private key is stored

WM-App does **not** put your raw `nsec` directly in Keychain, Android
Keystore, or a Linux keyring. Instead, it uses a two-part local vault:

- Your raw `nsec` is encrypted with AES-256-GCM. The ciphertext and public
  information such as your `npub`, together with the salt, nonce, and other
  data needed to unlock the vault, are stored in the app's normal preferences.
- A 256-bit vault key is derived with PBKDF2-HMAC-SHA256 from your PIN and a
  random 32-byte per-install secret, using a separate random salt. The current
  code uses 210,000 PBKDF2 iterations.
- Only the random per-install secret is placed in the operating system's secure
  storage. The PIN is never stored. Your clear `nsec` exists only in app memory
  while the signer is unlocked.

The secure-storage location for that random per-install secret depends on your
device:

- **iPhone and iPad:** Apple Keychain. WM-App uses the package defaults: the
  item is accessible while the device is unlocked and iCloud Keychain
  synchronisation is off.
- **Android:** AES-GCM encrypted storage. Under the package defaults, its data
  encryption key is wrapped with RSA-OAEP using a wrapping key protected by
  Android Keystore. This is the extra protection for the random per-install
  secret, not storage of the raw `nsec` itself.
- **macOS:** Apple Keychain. Nostr Browser retains a WMAPP-specific secure-storage
  service name in the macOS data-protection keychain. Builds from before
  0.1.6 used the plugin's generic traditional-keychain service name; the app
  copies that legacy device secret forward on the next successful unlock.
- **Linux:** `libsecret`, which talks to the desktop Secret Service—normally
  GNOME Keyring or KDE KWallet.

These are the settings in the current app. WM-App does not currently request
Secure Enclave protection or native biometric/user-presence enforcement. It
also does not promise that vault data will survive uninstalling and
reinstalling the app, or that secure-storage keys are hardware-backed on every
device.

After upgrading from an older macOS build, unlock the signer once before
removing any legacy `flutter_secure_storage_service` Keychain item. Cleanup is
optional after a successful unlock because WM-App reads the migrated
WMAPP-specific item first.

The browser prototype has an address bar for loading arbitrary `http` and
`https` websites. The injected NIP-07 surface supports `getPublicKey`,
prompt-backed `signEvent`, empty `getRelays`, and prompt-backed
`nip44.encrypt`/`nip44.decrypt` on desktop through `wmapp-core`. NIP-44 is not
mobile-native yet. NIP-04 still returns explicit not-yet-supported errors.
NIP-98 remains more restrictive: both the loaded
WebView origin and the requested NIP-98 target origin must be trusted before
the native approval prompt appears. Remembered NIP-98 approvals and signer
audit entries are persisted locally, and the Signer tab can revoke approvals or
clear the audit log. A static signer test page is served from the Flutter web
build at `/signer-test.html` for native WebView/manual bridge checks.

Fresh dev builds use the configured development channel and a browser home page
with Flight Deck and Publisher Autopilot bookmarks:

- Tower URL: `https://tower.example.com`
- Flight Deck URL: `https://flightdeck.example.com`
- Autopilot URL: `https://autopilot.example.com`
- Trusted origins: local Tower/dev Flight Deck, `service-1.example.com`, `service-2.example.com`, and `service-3.example.com`

On first launch, the app asks for the `nsec` to sign with and a local PIN, then
creates the local signer vault described above.

The NStacks screen manages multiple named NStacks, their workspaces, the active
per-stack browser links/preferences, and one host for encrypted settings backup.
Eligible top-level pages receive the origin-consented `window.NStack` v1
discovery surface; discovery and document-scoped service capability approval
are separate. A reusable manual fixture is available at `/nstack-test.html`.
The exact API, error and revocation semantics are in
[`docs/nstack-browser-contract.md`](docs/nstack-browser-contract.md).

Settings backup uses a pure-Dart NIP-44 v2 implementation shared by desktop and
mobile builds. It uploads only ciphertext to the selected host NStack and
publishes a signed, self-encrypted NIP-78 recovery pointer. This does not change
the older `window.nostr.nip44` bridge note above: general website-requested
NIP-44 operations still follow their existing platform path.

Do not put signer nsecs in `.env.local` anymore. That file is only for local
development overrides such as `WMAPP_CORE_BIN`:

```bash
cd ~/code/nbrowser
cp .env.local.example .env.local
$EDITOR .env.local
```

Then launch through the root helper scripts:

```bash
./build_runapp.sh  # pull Nostr Browser, build Flight Deck, build app, launch
./runapp.sh        # launch the existing macOS build
```

`runapp.sh` sources `.env.local` and passes `WMAPP_REPO_DIR` to the app. The
signer identity still comes from the encrypted onboarding vault, not from shell
environment variables.

The current macOS development build disables the app sandbox because the Flutter shell still invokes the Rust core through `cargo run`. Production packaging should bundle and execute a signed `wmapp-core` binary from inside the app instead.

macOS signer/browser development builds do not require macFUSE or `fuse.pc`.
The Rust core uses fuser's `macos-no-mount` build mode on macOS so NIP-07 and
NIP-98 signing can compile on a normal laptop. The kernel Drive mount remains a
separate packaging target.

When launching the macOS app from Finder, the Flutter bridge looks for the Rust workspace in `WMAPP_REPO_DIR`, the current directory parents, `~/code/nbrowser`, the legacy `~/code/wingmanbefree/wm-app` checkpoint, or `~/wm-app`. If the repo is cloned elsewhere, launch with `WMAPP_REPO_DIR=/path/to/nbrowser open "build/macos/Build/Products/Debug/Nostr Browser.app"`.

Flutter platform folders have been generated for macOS, Linux, web, Android,
and iOS. To validate the shell locally:

```bash
cd app
flutter pub get
flutter test
flutter build web
flutter build macos --debug
flutter run -d macos
```

Root helper scripts are available for the most common local builds:

```bash
./build_runapp.sh          # macOS debug build, then launch
./build_linux.sh           # Linux release bundle with bundled FIPS
./build_android_apk.sh     # Android debug APK
./build_ios_debug.sh       # iOS device debug build without codesigning
./build_ios_debug.sh simulator
```

The Android APK is written to:

```text
app/build/app/outputs/flutter-apk/app-debug.apk
```

The iOS debug builds are written to:

```text
app/build/ios/iphoneos/Runner.app
app/build/ios/iphonesimulator/Runner.app
```

Mobile status:

- Browser shell, home bookmarks, WebView browsing, policy prompts, encrypted local signer onboarding, NIP-07 `signEvent`, and NIP-98 signing are mobile-ready.
- Drive sync, device registration, channel validation, local file mounting, and NIP-44 encryption/decryption still use the desktop `wmapp-core` process path and need a mobile-native bridge in a later package.

Desktop FIPS status:

- Setup → FIPS transport includes a persisted WMapp FIPS on/off switch. Off
  cancels app mesh retries and transport resources; the separately installed
  desktop system daemon remains independently managed. See
  [Desktop FIPS control and diagnosis](docs/desktop-fips-control.md).
- macOS bundles the pinned upstream package and activates it through the normal
  administrator authorization dialog.
- Linux bundles the pinned upstream systemd release for x86_64 or aarch64. On
  first `.fips` navigation WM-App uses `pkexec` to install/repair it, enable the
  daemon and split-DNS service, preserve any existing identity, and connect the
  authenticated no-DNS bootstrap. This path supports Ubuntu and
  Arch/systemd-based Omarchy without a separate FIPS download.

Operational handoffs, worker briefs, device installation results, screenshots,
and run-specific validation evidence stay locally under `tmp/docs/handoffs/`.
They are ignored by Git. Keep reusable product documentation and test procedures
under `docs/`; use generic device labels and placeholders in examples. Do not
force-add handoffs or link public documentation to private evidence files.

See:

- [Architecture](docs/architecture.md)
- [Decision Backlog](docs/decisions.md)
- [Implementation Plan](docs/implementation_plan.md)
- [Tower Route Inventory](docs/tower_route_inventory.md)
- [Tower Drive Contract](docs/tower_drive_contract.md)
- [Device Key Contract](docs/device_key_contract.md)
- [API Gap Harness](docs/api_gap_harness.md)
- [WApp Signer Trust Contract](docs/wapp_signer_contract.md)

Builds that fetch Flight Deck require `FLIGHT_DECK_PG_APP_NPUB` set to the verified deployment app identity. Configure release publisher and App Store settings locally as described in the deployment guides; public configuration contains no personal publisher identity.
