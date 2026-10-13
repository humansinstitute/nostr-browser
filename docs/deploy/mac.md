# Mac Build And Install

## Fastest Path

Use the root helper script. It pulls Nostr Browser with `git pull --ff-only`, downloads, builds and bundles the latest Flight Deck from GitHub, fetches Flutter dependencies, builds the macOS debug app, and launches it. See the [shared prerequisites](../../README.md#repository-checkout) for Flight Deck source and tooling setup.

```bash
cd ~/code/nbrowser
git pull --ff-only
./build_runapp.sh
```

After the first successful build, relaunch the existing app without rebuilding:

```bash
cd ~/code/nbrowser
./runapp.sh
```

Logs go to:

```text
$TMPDIR/wingman_app.log
```

## Fresh Mac Setup

Install Flutter and Xcode command line tooling first:

```bash
flutter --disable-analytics
xcode-select --install
sudo xcodebuild -runFirstLaunch
sudo xcodebuild -license accept
flutter doctor
```

If `flutter doctor` says CocoaPods is missing, install it before iOS work. macOS debug builds usually do not need CocoaPods unless a plugin path requires it.

## Manual Build

This is the canonical certificate-free local build. The Xcode project uses an
ad-hoc identity for Debug, Profile, and the unsigned Release staging build, so
neither an Apple Developer team nor a development certificate is required:

```bash
cd ~/code/nbrowser/app
flutter pub get
flutter build macos --debug
open "build/macos/Build/Products/Debug/Nostr Browser.app"
```

The debug app is intentionally local-only. Its signature can be inspected with:

```bash
codesign --verify --deep --strict --verbose=2 \
  "build/macos/Build/Products/Debug/Nostr Browser.app"
codesign -dvv --entitlements - \
  "build/macos/Build/Products/Debug/Nostr Browser.app"
```

Only `com.apple.security.cs.allow-jit` is requested by Debug/Profile because
Flutter's debug runtime needs JIT execution. Nostr Browser is deliberately not sandboxed
for its local core bridge, so sandbox network entitlements are neither required
nor claimed. Packaging applies the selected distribution signature after the
certificate-free Flutter staging build.

## Private Mac-to-Mac DMG

The default release helper restores the private installation path. It signs the
app and DMG with the first available `Apple Development` identity, retains the
stable `com.wingmanbefree.wmapp` bundle ID, and does not contact Apple's notary
service:

```bash
./tools/build_macos_dmg.sh --local
```

Set `MACOS_LOCAL_SIGN_IDENTITY` to the exact identity name or SHA-1 hash when
using a private/self-signed Code Signing certificate or when more than one
local identity is installed. The identity must appear in
`security find-identity -v -p codesigning`. The private key remains only in the
build Mac's Keychain. Export only the public certificate (never the private key)
when a self-signed certificate must be trusted on another Mac.

On the target Mac, verify the reported SHA-256 before opening the DMG. An Apple
Development build normally needs no certificate import, but it is not a public
Developer ID release: after copying Nostr Browser to Applications, Control-click it,
choose **Open**, and confirm once. For a private self-signed identity, first
import its public certificate into the login Keychain and set that certificate
to **Always Trust** for Code Signing, then use the same Control-click **Open**
flow. Trusting that certificate permits code signed by that private identity;
only do this for a certificate received and fingerprint-checked out of band.

The bundled FIPS 0.5.0 installers remain checksum-pinned upstream packages in
private mode. Open the matching package from
`Nostr Browser.app/Contents/Resources/FIPS` with Control-click **Open**, approve the
installer, and use arm64 on Apple silicon or x86_64 on Intel. This is a
per-package local trust decision and does not disable Gatekeeper globally.

Ad-hoc signing (`--ad-hoc`) has no persistent signer identity and can cause
Keychain ACL prompts after every rebuild. It remains a diagnostic mode, not the
private cross-Mac installation path.

Nostr Browser stores its vault secret in the traditional macOS Keychain under the
WMApp-specific service `com.wingmanbefree.wmapp.signer-vault`. It does not claim
`keychain-access-groups`: Apple treats that as a restricted entitlement that
must be authorized by a provisioning profile, whereas this app does not share
the item with another target. The stable bundle ID and stable signing identity
let macOS retain the expected per-app Keychain ACL across upgrades.

## Public Release DMG

A public DMG requires a `Developer ID Application` identity and an existing
notarytool keychain profile. Because FIPS is installed separately by macOS, it
also requires a `Developer ID Installer` identity. The helper never stores
credentials:

```bash
MACOS_NOTARY_PROFILE=wmapp-notary ./tools/build_macos_dmg.sh --public
```

Set `MACOS_SIGN_IDENTITY` only when more than one Developer ID Application
identity is installed. The helper builds the universal release app, signs and
verifies it, creates and verifies the DMG, submits it for notarization, staples
the accepted ticket, runs Gatekeeper assessment, and prints the SHA-256. Before
signing the app, it verifies the pinned upstream SHA-256 of each architecture's
FIPS package, Developer ID Application-signs its three executable payloads with
the hardened runtime and a trusted timestamp, then Developer ID Installer-signs
the reproducibly repackaged installer. It submits each package separately to
Apple and staples and validates each accepted ticket. `FIPS/provenance.json`
records the upstream source/checksum, executable checksums before and after
signing, signed-and-stapled package checksum, architecture, Apple submission ID,
and acceptance status for the packages embedded in that app build.

For local packaging diagnostics only, `./tools/build_macos_dmg.sh --ad-hoc`
creates a clearly non-notarized artifact. It is not suitable for a public
release or normal installation on another Mac. It is the certificate-free DMG
mode and is expected to fail Gatekeeper assessment after download. To test it
locally without changing system-wide security settings, mount it, copy Nostr Browser to
Applications, then Control-click **Open** and approve that exact app once.

An Apple Development-signed `--local` DMG is also not notarized and therefore
is expected to fail command-line Gatekeeper assessment on another Mac. It is a
private transfer artifact, not the file to publish as a normal download. A DMG
offered as a public download must be produced by `--public`; a renamed `--local`
or `--ad-hoc` artifact is a packaging defect even when its checksum, universal
architectures, bundled Flutter runtime, and internal code signature are valid.

The Xcode build bundles the pinned FIPS v0.5.0 macOS packages for both arm64
and x86_64. `tools/prepare_fips_macos.sh` downloads them from the upstream
release into an ignored cache and refuses a checksum mismatch. Generated
binaries are not committed.

## FIPS WApp PoC

After unlocking WMapp, open **Setup → FIPS transport**:

1. Choose **Open FIPS app** and paste the exact
   `http://<autopilot-npub>.fips:<port>/` URL or matching JSON descriptor.
   If the bundled runtime has not been activated, or its Wingman mesh setup is
   outdated, WMapp performs the repair automatically and macOS requests one
   administrator authorization. The separate **Install or repair** control
   remains available for diagnostics and explicit repair.
2. Activation preserves any existing FIPS key and unrelated configuration. The
   bundled helper transactionally enables persistent machine identity, Nostr
   rendezvous and UDP advertising under the `wingman-fips-poc-v1` application
   namespace. Scoped LAN rendezvous is also enabled so two Wingman machines on
   the same physical network do not depend on router NAT hairpin support. For
   this explicit same-LAN PoC, RFC1918/ULA candidates are included only inside
   encrypted Nostr traversal offers. An initial config backup is kept alongside
   `fips.yaml`.
3. The optional diagnostic probe is off by default and does not establish a
   route. Approve trust for the exact origin; WMapp never trusts `*.fips`.

FIPS machine identity is separate from the WMapp user signer. No FIPS private
key is copied into Flutter settings, command arguments, or logs.

The upstream v0.5.0 `.pkg` files are unsigned. Public release packaging verifies
each original package checksum, expands it, signs only its three executable
payloads with a Developer ID Application identity, flattens it, applies the
Developer ID Installer signature, notarizes it, and staples Apple's ticket
before embedding it in Nostr Browser. The provenance manifest records the transformation.
Private and ad-hoc builds retain the checksum-pinned unsigned upstream packages.
Private builds use a stable signing identity for direct Mac-to-Mac installation;
ad-hoc builds are suitable only for local diagnostics. Do not disable
Gatekeeper globally to work around a signature or notarization failure.

## First Launch

On first launch Nostr Browser asks for:

- the nsec to use for signing;
- a local PIN.

The nsec is encrypted into the app's local signer vault. Do not put signer keys in `.env.local`.
The macOS vault device secret is stored under WMAPP's own Keychain service name.
Older local builds may have a legacy `flutter_secure_storage_service` item; the
app migrates it on the next successful unlock, so manual cleanup should wait
until after that unlock has succeeded.

## Updating

```bash
cd ~/code/nbrowser
git pull --ff-only
./build_runapp.sh
```

Set `WMAPP_SKIP_CLEAN=1` if you want a faster rebuild:

```bash
WMAPP_SKIP_CLEAN=1 ./build_runapp.sh
```

## Current Notes

- The macOS debug app is unsigned development output.
- `runapp.sh` launches the built app executable directly and sources `.env.local` for development-only overrides.
- Finder launch can work, but `runapp.sh` is the reliable path because it sets `WMAPP_REPO_DIR`.
- macFUSE is only needed for the future live Drive mount path. Browser/signer testing does not require it.
