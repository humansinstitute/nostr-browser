# Packaged NStack administration

The new-tab NStack administration entry opens reviewed static application assets
on a random IPv4 loopback port under a random 256-bit capability path. It does not
restore the retired Flight Deck server. HTML and scripts are never fetched from
a service or connection descriptor. No HTTPS bootstrap is required.

The catalogue pins the SHA-256 of `assets/nstack-shell/manifest.json`. Before
binding a listener, the app checks that pin, manifest schema, every relative path,
content type and file hash. Only that immutable in-memory asset set is served.
The server requires its exact numeric Host and, when present, exact same Origin;
cross-site fetch metadata, writes, unknown paths and queries are rejected. CSP
blocks remote scripts, ambient HTTP/FIPS fetch, frames, workers and form submissions.
HTTPS API connections are allowed for explicitly previewed and confirmed signed
connection origins. The console enforces the selected endpoint, rejects redirects,
omits credentials, verifies a fresh nonce proof and never falls back automatically.
HTTPS permission does not permit remote HTML or executable resources.
Only the packaged index is an approved top-level provider document; remote or
subframe navigation from a shell tab is rejected. Deliberate address-bar navigation
leaves shell mode and the existing document lifecycle revokes its capabilities.

The native main-frame channels on macOS/iOS and Android retain their current
security checks. `window.fipsTransport` is the only service transport. Launch
approval is not endpoint consent or signing approval: exact endpoint, peer,
purpose and identity scope, concurrent grants and lifecycle revocation remain in
the existing provider. Every NIP-98 signature is fresh for its exact request.
The console owns signed, bounded v3 connection metadata validation, preview and
confirmation, and workspace authentication above transport. Connection metadata
must contain no secrets or grants.

## Updating the package

Tower owns `scripts/build-nstack-shell.ts`, producing ignored `dist/nstack-shell`.
The producer supplies only known relative assets and this manifest contract:

```json
{
  "schemaVersion": 1,
  "id": "nstack",
  "sourceRevision": "<full 40-character source commit SHA>",
  "entrypoint": "index.html",
  "files": {
    "index.html": {"sha256": "<SHA-256>", "contentType": "text/html"}
  }
}
```

Review the complete producer diff and output before importing. External scripts
and styles must be local files referenced relatively, compatible with strict CSP.
No inline script, eval, remote executable resource, service worker or dynamic HTML
proxy is permitted. Record the reviewed manifest digest separately, then run:

```sh
python3 tools/import_nstack_shell.py /path/to/tower/dist/nstack-shell <reviewed-manifest-sha256>
cd app
flutter test test/packaged_nstack_shell_test.dart test/tower_bridge_configuration_test.dart test/grasp_browser_consent_test.dart
flutter analyze
```

Commit the complete asset set, catalogue pin and Flutter asset declarations
together. The import command reads local files only and copies only manifest
members; review the resulting diff. A package update ships in a new app build,
never as remotely supplied HTML or script. Empty/missing pins and missing or
corrupt assets fail closed with an actionable installation message.

## Platform acceptance

Source tests do not establish live acceptance. Verify launch, paste/scan metadata,
preview, explicit endpoint consent, separate signer consent, authenticated workspace
access, navigation/reload/lock/identity/tab revocation and reconnect in a real
WebView on each release platform. Linux currently lacks the generic native
main-frame message channel; the entry fails closed until that platform dependency
is implemented. Do not infer support from its WebView widget alone.

Android shared FIPS provider source `0.1.9+13` is unchanged. A new shell release
must use a version greater than 13, coordinated with the release owner; signing,
publication and activation are separate release work. Physical-device and signer
smoke results must be reported separately from source tests. No shared service
restart is needed for source validation.

For an owner to review an unsigned, non-debug Android artifact without accessing
signing keys, first commit the reviewed source, then use an isolated snapshot:

```sh
python3 tools/build_unsigned_android_release.py --commit <full-source-sha> \
  --build-number <coordinated-number-greater-than-13> \
  --output tmp/docs/handoffs/<new-build-directory>
```

The helper removes only the signing-required guard from that disposable copy,
unsets signing credentials and leaves release signing unconfigured. It never
edits the main checkout's Gradle or provider/Kotlin sources. Verify the artifact's
version, `debuggable=false` and absence of APK signatures before handing it to the
release owner. It is not an installable release until owner signing; do not use
the existing signing script or access keystore credentials for this check.
