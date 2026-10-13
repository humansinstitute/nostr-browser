# iPhone Build And Install

Nostr Browser uses **NBrowser** beneath the iPhone Home Screen icon. Updates
retain the existing bundle identifier, signing team, and app data.

## Reality Check

iPhone installs require Apple's signing flow. The easiest practical route is:

1. Build from a Mac with Xcode installed.
2. Open the iOS Runner project in Xcode.
3. Pick your Apple development team.
4. Run directly to a plugged-in iPhone.

For wider testing later, use TestFlight.

## Fastest Path: iPhone Simulator

This does not install on a physical phone, but it is the fastest iOS smoke test.

```bash
cd ~/code/nbrowser
git pull --ff-only
./build_ios_debug.sh simulator
```

Then open a simulator from Xcode or run directly:

```bash
cd ~/code/nbrowser/app
flutter devices
flutter run -d <simulator-id>
```

## Standalone Physical iPhone Install

An app that Owner can reopen from the Home Screen must be a release build. Flutter
debug builds on physical iPhones are development artifacts that expect a Flutter
tool or Xcode debugger connection; do not install a debug build as a standalone
test build.

Build the signed release artifact using the existing Xcode signing configuration:

```bash
cd ~/code/nbrowser
git pull --ff-only
./build_ios_release.sh
```

The release helper rebuilds the FIPS core and automatically clones and builds
the latest Flight Deck `main` from `https://github.com/OtherStuffAI/wm-flightdeck.git`.
It logs the fetched source commit and build number, then verifies and bundles
the generated assets before Flutter builds. `FLIGHT_DECK_DIR` explicitly overrides
this with a local checkout; unset it when requesting upstream main. The resulting
device app is `app/build/ios/iphoneos/Runner.app`.

The default follows published GitHub main, which can lag committed local main.
When the task explicitly requires newer local commits, clone that exact main
into an isolated checkout, install its locked dependencies, and set
`FLIGHT_DECK_DIR` to it. Build fresh and record the exact commit; do not use a
dirty working tree or stale dist as evidence of latest source.

Install and launch it on the connected phone:

```bash
xcrun devicectl device install app \
  --device <physical-iphone-udid> \
  app/build/ios/iphoneos/Runner.app
xcrun devicectl device process launch \
  --device <physical-iphone-udid> \
  com.wingmanbefree.wingmanApp
```

A previously paired and trusted iPhone can be updated over Wi-Fi. Check
`xcrun devicectl list devices` and `xcrun devicectl device info details
--device <physical-iphone-udid>` before installing. Confirm the intended paired
device reports `transportType: localNetwork`; use its returned identifier in the
commands above. Query `device info apps` after installation to confirm the
installed version/build, and `device info processes` after launch to confirm the
returned process is still running. Keep device output in ignored local evidence.
Install in place with the existing bundle; do not uninstall to update.

Keep the phone unlocked during installation and launch. Verify that the Runner
process remains present and visually confirm that the first Flutter screen
renders; installation by itself is not launch verification.

## Interactive Debugging On A Physical iPhone

Use Xcode or `flutter run` when an attached debugger is intended:

```bash
cd ~/code/nbrowser/app
flutter run -d <physical-iphone-udid>
```

Alternatively, open the Xcode workspace and press Run:

```bash
open app/ios/Runner.xcworkspace
```

In Xcode:

1. Select `Runner` in the project navigator.
2. Select the `Runner` target.
3. Open `Signing & Capabilities`.
4. Select your Apple development team.
5. Confirm the bundle identifier is unique for your account.
6. Connect the iPhone by USB.
7. Select the iPhone as the run destination.
8. Press Run.

The current bundle identifier is:

```text
com.wingmanbefree.wingmanApp
```

Keep the existing bundle identifier and team. If Xcode reports that the
identifier is unavailable, restore access to the authorized team and its App ID;
changing the identifier creates a different app and breaks the release path.

## First Launch

On first launch Nostr Browser asks for:

- the nsec to use for signing;
- a local PIN.

The nsec is encrypted into the iOS app's secure storage backed signer vault.

## Trusting A Developer Build

If iOS blocks the app after install, trust the developer profile on the iPhone:

```text
Settings -> General -> VPN & Device Management
```

Choose the developer profile and trust it.

## Current iPhone Notes

- Browser and signer flows are the main mobile test target right now.
- Desktop-only process-backed features should report unavailable on iPhone until those paths are made native.
- `build_ios_release.sh` uses the existing Xcode project signing configuration and produces the standalone device artifact.
- `build_ios_debug.sh device` remains available only for debugger-attached development; it builds with `--no-codesign` and Xcode handles signing when you run to the phone.
- If dependencies fail, run:

```bash
cd ~/code/nbrowser/app
flutter clean
flutter pub get
cd ios
pod install
```

## TestFlight

`build_ios_release.sh` produces a development-signed device app; it does not
publish to TestFlight. Use the separate archive/export helper:

```bash
./build_ios_testflight.sh
```

This uses `app/pubspec.yaml` for the version/build and preserves bundle
`com.wingmanbefree.wingmanApp`, team `<existing-apple-team>`, and the existing app icon.
Before uploading, check the app's existing App Store Connect builds and increase
the build number if already used. Local version increments alone cannot prove
uniqueness in App Store Connect.

The helper produces `app/build/ios/archive/Runner.xcarchive` and, when distribution
signing succeeds, an IPA under `app/build/ios/ipa/`. It checks for a newly exported
IPA because Flutter can exit 0 after a successful archive but failed export.
`docs/deploy/TestFlightExportOptions.plist` requests App Store Connect export,
automatic signing for the existing team, internal testing only, and no automatic
version rewriting. Local export does not upload or select a tester group.

To retry export of an existing archive after repairing distribution signing:

```bash
xcodebuild -exportArchive \
  -archivePath app/build/ios/archive/Runner.xcarchive \
  -exportPath app/build/ios/ipa \
  -exportOptionsPlist docs/deploy/TestFlightExportOptions.plist \
  -allowProvisioningUpdates
```

This requires authorized Apple Developer Program distribution access, an App
Store Connect app record for the existing bundle, and working Xcode account or
App Store Connect API authentication. A development signing identity by itself
does not establish distribution eligibility. Do not replace the bundle/team to
work around an account failure.

`No Accounts` from CLI export does not prove Xcode is signed out. Check the
account/team in Xcode Settings, then use Organizer if its account access works.
See [TestFlight release checks](testflight.md) for certificate creation, profile
repair without upload, and handling a local Keychain approval prompt.

For upload using the signed-in Xcode account, open the archive in Xcode Organizer,
validate it, then distribute using **TestFlight Internal Only**. A CLI upload can
use a copy of the export plist with `destination` set to `upload`, retaining
`testFlightInternalTestingOnly=true`. Keep credentials out of repo files and logs.

After Apple accepts the upload, separately verify processing completion, answer
export-compliance questions based on the app's actual encryption, and add the
build only to Owner's existing private/internal testing group. Do not infer that
upload acceptance means the build is available to Owner. Do not create a public
link or invite additional people. Record the Apple receipt/build ID, processing
state and tester availability in the release handoff.

See [TestFlight release checks](testflight.md) for the encryption inventory,
account recovery, artifact verification, and private tester acceptance checks.

Official references: [Flutter iOS release guide](https://docs.flutter.dev/deployment/ios),
[Apple distribution workflow](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases),
and [Apple internal testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers).

## Native FIPS VPN

See [native iPhone FIPS](ios-fips.md) for the pinned Rust build, Packet Tunnel
signing profiles, split routing, extension-private node identity, diagnostics,
and physical-device checklist. The native runtime is now included in source;
Network Extensions provisioning is required before a signed device install.

Apple signing is local: export `WMAPP_APPLE_TEAM` with the verified existing team before a signed build. Signed build helpers generate ignored signing settings and export policies under `tmp/docs/handoffs/apple-signing/`; the bundle identifiers remain unchanged. For command-line Xcode or manual Flutter builds, run `export XCODE_XCCONFIG_FILE="$(python3 tools/ios/configure_apple_signing.py)"` from the repository root first. Never commit local team values or generated policies.
