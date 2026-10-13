# Native iPhone FIPS

WMAPP bundles FIPS 0.5.0 in `FipsPacketTunnel.appex`. Runner manages normal iOS
VPN consent through `NETunnelProviderManager`; Rust runs only inside the
extension. This is the FIPS mesh protocol, not a claim of FIPS 140 certification.

## Build

Prerequisites: Xcode, Flutter, Rustup, Git, Python 3. Rust is pinned to 1.98.0 and
upstream FIPS to `80f8f965aa872296edbce84ade9949ece2596602`. The iOS crate has an
independent Cargo workspace/lockfile so its portability patch cannot change
Android's dependency resolution.

From the WMAPP repository:

```sh
rustup toolchain install 1.98.0 --profile minimal --component rustfmt \
  --target aarch64-apple-ios,aarch64-apple-ios-sim,x86_64-apple-ios
./tools/ios/build_core.sh
cd app
flutter pub get
flutter build ios --simulator --debug
flutter build ios --release --no-codesign
```

`build_core.sh` exports the exact upstream revision from an ignored Git cache,
applies checked source transformations in `tools/ios/prepare_core.py`, uses the
locked dependency graph, and creates `app/ios/FipsCore/WmFips.xcframework` for
arm64 device and arm64/x86_64 simulator. Generated Rust source and binary assets
are ignored. Do not edit them; change the preparation script. The existing
`build_ios_debug.sh`, `build_ios_release.sh` and `build_ios_testflight.sh` wrappers
prepare this library automatically. The TestFlight helper is not needed for
local device testing and was not used to publish this change.

The checked-in Xcode project embeds the extension before Flutter's Thin Binary
phase. `tools/ios/integrate_project.rb` is an idempotent maintenance helper
(requires the xcodeproj Ruby gem), not a build prerequisite. If building directly
from Xcode after a fresh checkout or Rust changes, prepare the XCFramework first.
Runner and the extension both read Flutter's generated version/build settings.

## Signing and physical installation

Keep the existing team `<existing-apple-team>` and identifiers:

- Runner: `com.wingmanbefree.wingmanApp`
- Extension: `com.wingmanbefree.wingmanApp.FipsPacketTunnel`

Both targets require `com.apple.developer.networking.networkextension` with
`packet-tunnel-provider`. They need explicit capability-enabled provisioning
profiles. An old wildcard profile that can install Runner without a VPN does
not satisfy the extension requirement. Sign in to the authorized existing
Xcode account and enable Network Extensions for both App IDs; do not change
team/identity to work around missing account access. No shared Keychain group
or App Group is needed: Runner cannot retrieve the extension node key.

```sh
cd app
flutter build ios --release
# Use the device identifier returned by `xcrun devicectl list devices`.
xcrun devicectl device install app --device <physical-iphone-udid> \
  build/ios/iphoneos/Runner.app
xcrun devicectl device process launch --device <physical-iphone-udid> \
  com.wingmanbefree.wingmanApp
```

Never install unsigned output. A successful development install does not
establish TestFlight/App Store distribution access. Verify that both signed
targets and provisioning profiles permit `packet-tunnel-provider` and include
the paired iPhone. Install the signed release in place and launch without a
debugger, then run the physical consent, tunnel and WApp checks below. Keep
machine-specific install evidence and Flight Deck bundle provenance in ignored
local `tmp/docs/handoffs/` records.

## Routing, identity and lifecycle

- Public `packetFlow.readPackets`/`writePackets` exchange raw IP packets. There
  is no private utun descriptor extraction or system-TUN configuration.
- Only `fd00::/8` and the DNS-only IPv4 route `10.1.1.1/32` enter the tunnel.
  `NEDNSSettings.matchDomains = ["fips"]` selects split DNS with no search
  suffix. Ordinary internet/DNS keep system routing. Public or mixed questions
  mistakenly sent to the intercepted DNS address receive REFUSED, never a
  public fallback. Malformed/fragmented DNS packets are rejected.
- The extension generates a separate 32-byte node secret in its own Keychain,
  `AfterFirstUnlockThisDeviceOnly`. It persists across stop/restart and is
  available after screen lock following first unlock. It is never sent to
  Runner, Flutter, JavaScript, or diagnostics. Repair does not rotate it.
- Swift serializes lifecycle and packet work. One packet read is outstanding;
  each batch is limited to 64 packets. Generations reject stale callbacks.
  A network path transition recreates UDP/node state after a one-second debounce
  using the same Keychain identity. Generic and physical Wi-Fi monitors observe
  all subsequent path updates, including same-interface changes. One cancellable
  debounce timer coalesces updates. No on-demand VPN rules are installed.
- Packet output uses a native readiness descriptor and `DispatchSourceRead`,
  with up to 32 packets / 128 KiB per event. Idle output has no polling timer;
  a separate health check runs every five seconds. Rust owns queue endpoints;
  Swift owns one duplicate, closed only by the dispatch cancellation handler.
  No Swift context or callback pointer crosses FFI. Runtime death/abort signals
  EOF; rejected writes are terminal. Stop cancels all sources before stopping
  Rust. The outstanding OS read is preserved across runtime generations.
- Controller preference-load callbacks are operation-scoped. Stop keeps the
  operation reserved until disconnect/timeout, preventing a late stop callback
  from stopping a replacement. Repair confirms disconnect before starting.
- Rust limits input TUN to 64 × 1280-byte packets and DNS requests to
  16 × 1280 bytes. Mesh output and DNS replies share a queue capped at 64 packets
  and 128 KiB (4096 bytes per output packet). Transport ingress and encrypt work
  remain capped at 64. There is one
  encrypt worker, no decrypt pool, and two Tokio workers with 2 MiB stacks.
  DNS uses one worker with a two-second socket timeout. Stop cancels queued
  DNS and joins that worker, bounds node shutdown to three seconds and runtime
  shutdown to one second. Full queues drop packets rather than grow/block.
- The leaf config caps peers at 4, connections/links at 8, pending inbound
  handshakes at 16, sessions at 32, and pending session destinations at 16.
  These bounds are not a measured iPhone peak-memory claim.
- Startup errors, consent/save failures, timeouts, stop and repair reach Dart
  through the existing native channel. Setup exposes Stop FIPS and diagnostics
  export. iOS may disconnect another active VPN; it controls that policy.
- The optional end-to-end diagnostic probe currently reports unavailable on
  iPhone. Users can continue to the exact WApp URL; unavailable never means a
  successful probe. Authenticated bootstrap readiness is checked separately.

## WApps and trust

URLs remain exactly `http://<npub>.fips:<port>/`. Runner adds an ATS exception
only for the `fips` domain and subdomains because `NSAllowsLocalNetworking`
does not cover this custom TLD. It permits HTTP carried over the authenticated,
encrypted FIPS mesh; it does not disable ATS globally or trust a signer origin.
Existing exact-origin `window.nostr` approval remains mandatory. There is no
wildcard signing approval. Embedded Flight Deck retains its existing origin,
secure context, Dexie cache and TowerSyncService ownership. This runtime does
does not establish live consumer acceptance for the universal browser FIPS
transport on iPhone; that requires a separately evidenced iOS WebView pass.

The pinned public `test-us01` bootstrap (`217.77.8.91:2121`) is a PoC dependency,
not production availability. This mobile leaf uses bootstrap routing. LAN and
Nostr rendezvous, UDP advertisement and local candidate sharing are also enabled
in the `wingman-fips-poc-v1` scope for peer reachability. They were enabled after
the initial event-driven refinement; its earlier discovery-disabled measurements
are not a baseline for the current configuration. Relay subscriptions, discovery,
heartbeats and reconnection can continue while the tunnel is connected.

## Diagnostics and repeatable validation

Setup -> FIPS transport -> Export diagnostics opens the iOS Files exporter.
The JSON contains fixed lifecycle event codes, timestamps, app/core version and
VPN status. It excludes keys, identity, URLs, packets and arbitrary error text.
Only the most recent 100 events of the current app process are retained, in
memory; Clear diagnostics clears them. Temporary export data is removed when
the picker completes/cancels. No extension packet logging is enabled.

```sh
python3 tools/ios/prepare_core.py
RUSTC="$(rustup which --toolchain 1.98.0 rustc)" \
  rustup run 1.98.0 cargo test --manifest-path crates/wmapp-fips-ios/Cargo.toml --lib
# Explicit network smoke: ephemeral identity, authenticated public bootstrap,
# AAAA resolution through the packet DNS boundary. This runs on the Mac.
RUSTC="$(rustup which --toolchain 1.98.0 rustc)" \
  rustup run 1.98.0 cargo test --manifest-path crates/wmapp-fips-ios/Cargo.toml \
  live_authenticated_bootstrap -- --ignored --nocapture
# Production Swift pump + real host Rust, lifecycle, bounds and ownership smoke:
./tools/ios/test_native.sh
cd app
flutter analyze
flutter test
```

Do not run `prepare_core.py` concurrently with a build using its generated
source. The Rust unit suite tests C buffer ownership/null handling, packet
bounds, queue saturation, malformed/fragmented DNS, reply checksums, real node
start/stop, duplicate starts and identity continuity. Repeated shutdown checks
ensure DNS worker counts return to zero. Swift checks split routes/DNS/MTU.
Flutter includes iPhone consent/errors/retry, status, coalescing, stop/restart,
diagnostics and existing exact-origin signing regressions.

## Required physical-device checklist

Record device/iOS/build, elapsed time, public node npub (never key), screenshot
or sanitized diagnostic evidence and pass/fail for each item:

1. Enable from Setup and accept Apple's VPN prompt normally; verify authenticated
   bootstrap readiness. Refuse consent in a separate attempt and verify retry.
2. Open an existing exact `.fips` WApp URL, resolve/load it, and complete its
   Nostr login with the expected exact-origin prompt. Verify a second origin
   needs its own approval. Do not change the embedded Flight Deck origin.
3. Load ordinary HTTPS and resolve ordinary public DNS while FIPS is active.
4. Stop, restart and repair repeatedly; verify the same node identity and no
   stale connected state after killing/relaunching Runner or an extension exit.
5. Lock the screen/background the app and reopen; observe connectivity and
   memory. Test after reboot/first unlock without silently generating a new key.
6. Switch Wi-Fi -> cellular -> Wi-Fi and test offline -> online. Verify recovery
   and WApp traffic, not only a connected VPN badge.
7. Enable with another VPN active, record the actual iOS transition, then stop
   FIPS and check ordinary network recovery. Do not assume two VPNs coexist.
8. Export/cancel/clear diagnostics after a startup failure. Inspect for secrets.

Simulator app launch, host core authentication, and unsigned device builds do
not pass these physical-device items. Simulator Network Extension behavior is
not evidence of physical iPhone packet routing.

Apple references checked for this implementation:
[Packet Tunnel provider](https://developer.apple.com/documentation/networkextension/nepackettunnelprovider),
[split DNS](https://developer.apple.com/documentation/networkextension/nednssettings/matchdomains),
[local ATS scope](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking).

### Simulator port collision

The iOS Simulator shares the Mac's network ports. If desktop WMAPP already
owns the fixed bundled Flight Deck origin `127.0.0.1:47831`, simulator Runner
can install/launch but fail to render with `Address already in use`. Coordinate
closing that desktop WMAPP only when its owner is ready, then relaunch the
simulator. Do not pick a random port, change the Flight Deck browser origin,
or silently reuse another instance's server as a workaround. The 2026-09-09
simulator test encountered this collision; its screenshot is not a visual pass.

### Event-driven refinement evidence

Keep reference comparisons, host idle/active measurements, final build hashes
and signing status in local `tmp/docs/handoffs/` records. The host smoke uses an
ephemeral node key, exercises
local REFUSED packet DNS and terminal readiness, and does not open/alter a VPN
or claim iPhone battery/underlay evidence. The separate ignored Rust network test
checks authenticated bootstrap and `.fips` AAAA resolution. Do not run source
preparation concurrently with either a host or cross-architecture Cargo build.

### Background CPU and traffic investigation

The iOS Battery app's percentage is an attribution of battery use during the
selected period, not percentage points of battery capacity. Background duration
does not identify Runner, WebKit or the packet extension, establish tunnel
connectivity, or identify a timer as the cause. Record the installed app version
and build and whether Setup reports FIPS connected before comparing runs.

For repeatable **macOS host** evidence, first finish source preparation and any
other native builds, then run:

```sh
python3 tools/ios/prepare_core.py
./tools/ios/measure_native.sh
# Repeat with health-check phase order reversed to expose startup/order effects.
WM_FIPS_HEALTH_FIRST=1 ./tools/ios/measure_native.sh
```

Run one measurement harness at a time: LAN discovery can cause simultaneous
ephemeral nodes to discover each other. Avoid unrelated heavy host workloads
and compare the actual elapsed duration and delivered packet rate.

This builds the production Rust core with the release profile and links the
production Swift output pump. Each run uses a fresh ephemeral identity and
temporary working directory, contacts the configured bootstrap/discovery
services, and removes the temporary directory after stopping. It does not open
a VPN, use a stored device key or run Runner/WebKit. Default measurement phases
are 30 seconds each (`WM_FIPS_MEASURE_SECONDS`, 10–300): stopped before start,
idle with health checks disabled/enabled, local REFUSED DNS at approximately
20 requests/second, and stopped after shutdown. A ten-second warmup precedes
idle phases. The normal 272-packet burst and terminal EOF/descriptor smoke also
run. The measured health timer reproduces the provider's five-second interval
and one-second leeway. Timer-disabled mode is limited to the host experiment.

Phase JSON records elapsed monotonic time, process CPU user+system seconds,
CPU percentage of one core, Darwin interrupt/package-idle wakeup counters,
output reads, health-check count, delivery count and failures. These wakeup
counters are specific kernel accounting categories, **not total wakeups**;
zero does not mean the process never ran. Bootstrap connectivity is sampled
outside each idle window and reported separately; `running` alone is not an
authenticated connection. Do not call a disconnected run a connected-idle test.

The wrapper samples `nettop` process TCP/UDP socket byte totals once per second.
Check
`traffic-errors.log` and actual rows before claiming network evidence. Correlate
wall-clock CSV sample times with JSON phase boundaries; use differences between
interior samples. Collection timestamps are not packet timestamps. A closed or
replaced socket can decrease totals; report such a window as unstable rather
than inventing a traffic delta. These include loopback and discovery,
exclude packetFlow attribution, and do not measure radio energy or air-interface
bytes. Output uses a new Git-ignored evidence directory; an optional first
argument selects another new ignored directory. Do not overwrite prior records.

Keep phase logs, traffic, device exports, screenshots and traces private and
ignored. Host CPU/network measurements cannot establish iPhone battery savings
or reproduce physical `NWPathMonitor`, iOS suspension or cellular radio behavior.
Changing discovery, maintenance/retry/heartbeat deadlines, or stopping the
tunnel automatically may break intended reachability; require evidence and
architecture review before making that tradeoff.

For immediate mitigation when `.fips` access is not needed, use Setup → FIPS
transport → Stop FIPS and confirm it is stopped in iOS VPN settings. Start FIPS
again when needed. This deliberately suspends `.fips` connectivity. Force-quitting
Runner alone is not a reliable way to stop its independent VPN extension.

For a physical-device A/B investigation:

1. Record generic device model, iOS version, installed WMAPP version/build,
   start/end time, charge level, charging state, network and tunnel state. Export
   current diagnostics before changing state. Ask whether the tunnel was connected
   during the originally reported interval; a later check cannot prove that.
2. On the same installed build, compare equal 60-minute locked-screen windows
   with FIPS stopped versus connected and idle. Use the same stable Wi-Fi,
   brightness, charge range and other activity; disconnect the charger for battery
   comparisons. Repeat in reverse order. Record Battery activity and charge drop,
   not only relative app percentages. Do not describe this as an old/new fix A/B.
3. With a connected development build, attach Instruments to Runner, the packet
   extension and WebKit processes as available. Record CPU, wakeups and Network
   traffic through foreground → background → lock → unlock. Instrumented/USB
   runs explain execution but are separate from unplugged battery comparisons.
   Use the Instruments device identifier from `xcrun xctrace list devices`;
   it can differ from the CoreDevice identifier used by `devicectl`. Keep both
   identifiers in private evidence. An attached process may have lifecycle
   `Unknown` until a transition occurs: record the actual screen/app state before
   labeling a capture background or idle. Keep Runner and WebKit attribution
   separate. For traffic, prefer connection/byte metadata; device-wide plaintext
   HTTP capture is not needed to measure background byte counts.
   Correlate provider start/stop/reassertion, path updates and bootstrap connection
   with bursts; the current app-only diagnostic export cannot prove path counts.
4. Compare idle with a repeatable active `.fips` WApp load, verify authenticated
   peer connectivity and packet delivery, then repeat on cellular and across
   Wi-Fi/cellular/offline transitions. Confirm ordinary HTTPS/DNS, stop/restart,
   identity continuity and exact-origin approvals. Include an empty browser tab
   versus embedded Flight Deck comparison if Runner/WebKit remains active.
5. If activity persists with the VPN confirmed stopped, investigate Runner/WebKit
   and the browser consumer rather than altering tunnel timers. If extension
   activity dominates, use its traces to separate discovery/retry, heartbeat,
   path-restart and packet load before testing any proposed correction.

The pinned bootstrap npub and UDP address identify the project's public test mesh, as documented in the configuration helpers. They are shared service references used consistently by the native runtimes and connectivity checks, rather than a user's device or personal signing identity. Retaining the exact pin preserves bootstrap authentication and connectivity. Bootstrap connectivity does not grant a browser origin permission to use FIPS: top-level-origin consent, exact endpoint/peer grants, authentication and lifecycle revocation remain enforced by the native transport contract.
