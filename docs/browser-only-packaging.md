# Browser-only packaging

Nostr Browser packages the general browser, Nostr signer, FIPS runtime, Drive
and NStack support. Ambulando is a separate native application. Browser builds
must never fetch or embed its frontend, run a local application server or check
for application frontend updates. External websites and WApps remain browsable
and bookmarkable with their complete URLs.

The shared Flutter asset manifest supplies macOS, iOS, Android, Linux and web
builds. Only launcher artwork is registered there. The platform build helpers
compile browser/native inputs; neither nightly release lane requires a Flight
Deck repository, app identity, frontend build or frontend source archive.
Windows has no platform runner in this repository. Do not imply a Windows
release was built from the Linux or web runner.

Legacy built-in startup flags are ignored. Saved bookmarks referencing the
retired exact HTTP endpoint `127.0.0.1:47831` are excluded when decoding both
local and NStack settings. Stored preferences are retained for recovery.
Titles never determine migration: an external URL named Flight Deck or
Ambulando remains an ordinary editable bookmark and can open on startup.
The former endpoint has no implicit protected capability permission. Manual
web navigation remains general purpose.

Generic `window.fipsTransport` and external compatibility adapters retain their
security contracts. HTTPS pages receive only the consent-gated provider. Local
HTTP WApps additionally need an explicitly configured loopback origin; native
channels enforce matching top-level frame origins, and the transport still
requires endpoint/peer/purpose consent. This does not grant service authentication.
Shared Tower/Drive/NStack clients and NIP-98 protocol code are independent of
bundling and remain in use.

## Reusable verification

```sh
python3 -m unittest discover -s tools/tests -p 'test_browser_only_package.py'
(cd app && flutter analyze && flutter test)
```

Drive HTTP integration tests require `cargo build --locked --release -p
wmapp-drive-fs` first. Release tests require the dependencies pinned in
`tools/ios/requirements-testflight.txt` and a synthetic `WMAPP_APPLE_TEAM` for
isolated fixtures. Use a verified real local team only for an authorized build.

Build available runners with Flutter's release build commands. Audit generated
Flutter asset directories and APK ZIP entries for `assets/flightdeck/` and
`assets/ambulando/`; neither prefix may appear. Android nightly validation also
rejects those payloads before delivery. Existing old release snapshots remain
historical evidence and must not be rewritten to pass the new policy.

Source commits and local release candidates do not update installed apps.
Distribution still requires platform signing, version reservation, applicable
store/privacy/compliance review, explicit delivery authority, upload/publication
and readback. Personal-device installation requires separate authority.
