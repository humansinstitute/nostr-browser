# Android shared FIPS readiness v1

Native approved apps reuse Nostr Browser's running system VPN and machine identity.
This IPC is readiness metadata and user consent, not a socket proxy, signer, or
browser bridge. `window.fipsTransport` remains the only browser transport.

The shared readiness provider requires Android 11/API 30 or newer, where the
provider can verify its own VPN owner UID. On Android 10 the existing VPN may
still run, but cross-app readiness fails closed as `unavailable`.

## Wire contract

Use `ContentResolver.call(Uri.parse("content://<provider-package>.fips.shared"),
method, arg, extras)`. Stable provider package is
`com.wingmanbefree.wingman_app`; nightly is that package plus `.nightly`.
Consumers must resolve the actual provider package and pin its enrolled durable
**current signing certificate SHA-256**, not trust authority/name/ownerUid alone.
The reviewed stable provider certificate SHA-256 is
`6c0da09b9e2375d657645f197419be7b8227a7434e0225512fc760cedf383c8c`.
The nightly provider returns `unavailable`; no nightly/debug provider is enrolled. A release certificate mismatch
must fail closed.

All replies contain `version` Int = 1 and `status` String. Methods:

* `request`, arg null: extras `version` Int=1, `endpoint` String exactly
  `http://<canonical-lowercase-npub>.fips:<decimal-port>` (no trailing slash),
  `peerNpub` String matching host, `purpose` String=`nstack`, and `callback`
  Parcelable `android.os.Messenger`. Callback is mandatory and app-owned.
  Reply `consent_required` includes `requestId` String and `consentIntent`
  Parcelable immutable `PendingIntent`. Launch only after showing the QR preview;
  retain that preview while pending. The provider never starts the VPN for callers.
* `check`, arg=requestId, extras `version` Int=1: pending gives `pending`,
  denial `denied`, expired/released/lost binding `revoked`. On approval gives
  `ready` and fields below. Check before DNS, socket creation and every new
  operation, and at least once per 15 seconds while any stream is open.
* `release`, arg=requestId, extras `version` Int=1: revokes that request/grant,
  returns `released`. Does not revoke another endpoint's concurrent grant.

`ready` fields: `requestId` String, `grant` String (same opaque value as
requestId), `endpoint`, `peerNpub`, `purpose`, `peerIpv6` String,
`peerIpv6Bytes` ByteArray(16), `networkHandle` Long, `generation` String,
`expiresAt` Long (Unix **seconds**), `expiresElapsedRealtime` Long (Android
monotonic milliseconds). `lifecycle` IBinder belongs to provider process;
linkToDeath and immediately cancel all grant I/O on death. Checks renew a
60-second lease, with a hard 10-minute consent lifetime. Never use a grant after
the monotonic deadline; a timer must close existing I/O then even if IPC stalls.

Messenger revocation: Message.what=1; data `version` Int=1, `requestId` String,
`status`=`revoked`. Pending consent expiry, client Binder death, release, stop,
lock/screen-off, native runtime loss, underlying/VPN network loss or capability
mismatch revoke. Callback delivery is advisory: enforce deadlines and Binder and
Network loss independently. Any failure or unknown status fails closed.

Other statuses: `unauthorized` (package/UID/certificate not enrolled),
`unsupported_version`, `invalid_request`, `unavailable` (VPN/runtime absent or
not safely identifiable), `busy` (bounded concurrent request limit),
`unsupported_method`. Missing provider is a client-side `provider_missing`;
wrong package/certificate is `provider_untrusted`. Neither permits HTTPS fallback.

The existing Android VPN is system-wide: readiness grants do not add kernel
per-endpoint socket restrictions to other apps. They attest provider readiness
and record app/endpoint consent. Only enrolled clients receive metadata, and
those clients must enforce the socket and application bindings below.

## Caller and consent security

Provider authenticates Binder UID and Android-verified calling package on **each**
call, requires exactly one package for that UID and exactly one current signer,
and compares its SHA-256 against the bundled explicit enrollment resource
`fips_shared_clients`. Entries are `<package>|<lowercase-64-hex-cert-sha256>`.
The enrolled production clients are:

| Package | Current signing certificate SHA-256 |
| --- | --- |
| `com.wingmanbefree.alexandria` | `47e74d3781655055e86a6873b42c9cf3ed3179d0c481bc4108051246d3ea81aa` |
| `studio.otherstuff.ambulando.android` | `95ae1a491e106931a25296797a6e99a9efe95a9e935609e98403afb8e91b816d` |

These public certificates were verified from durable release APKs by the release
owner. No other package or certificate is enrolled. There is no debug, same-UID,
arbitrary-app, supplied-certificate or installer-name bypass. Certificate rotation
requires a reviewed enrollment update.
Consumers reciprocally pin NBrowser's durable certificate in their own config.

Consent is a non-exported native Activity reachable only through a provider-created
immutable PendingIntent. It displays actual package, certificate fingerprint,
exact endpoint/peer/port and purpose. Allow is once for the captured generation;
Deny/back/cancel does not authorize anything. No remembered approval or exported
key/credential/signature is provided. Each endpoint gets its own request/grant.
The consent UI includes a revoke-all action; requesting a new consent prompt
also gives access to that action. Stopping/locking the VPN also revokes all grants.

## Network and application binding

Provider identifies its own VPN using Android's owner UID **inside NBrowser**,
exact native local IPv6, mesh route and FIPS DNS on its LinkProperties. Clients
must not rely on ownerUid (Android redacts it for external apps). Readiness binds
the captured Network handle and a fresh opaque runtime generation; it never
selects an ordinary network or silently switches a grant to a new network.

Consumer must use `Network.fromNetworkHandle(handle).socketFactory` and
`Network.getAllByName(host)` for **all** DNS/socket work, disable proxy/redirects,
and compare every returned/connected address against
`0xfd || SHA256(raw 32-byte x-only peer key)[0:15]`. Never process-bind a global
network. Keep endpoint and port exact for HTTP, SSE, WS and file requests. Close
responses, sockets, streams, uploads/downloads and pooled connections on revoke,
expiry, provider Binder death, client teardown, network loss or failed check.
Renewal must return identical endpoint/peer/network/generation, or cancel.

Readiness proves neither service health nor application identity. Before trusting
workspace metadata, the consumer verifies the backend's fresh signed nonce proof
against the QR backend identity, through the pinned endpoint. NIP-98 and service
permissions remain consumer responsibilities. No fallback to public DNS, another
VPN, global sockets, ordinary HTTPS, or a second private FIPS runtime is allowed.

## Validation and release

From `app/android`, use the repository's Android/JNI build setup:

```sh
./gradlew :app:testDebugUnitTest :app:assembleDebugAndroidTest
```

Install the debug app and test APK on an isolated emulator, then run:

```sh
adb shell am instrument -w \
  -e class com.wingmanbefree.wingman_app.fips.FipsSharedProviderTest \
  com.wingmanbefree.wingman_app.test/androidx.test.runner.AndroidJUnitRunner
```

These IPC tests cover unenrolled calling UIDs, forged caller
extras, production enrollment mismatches, and the non-exported consent Activity.

Before release, additionally run instrumentation with authorized and unauthorized
separately signed caller fixtures. Validate consent deny/back, caller spoof/shared
UID/cert changes, exact peer/port, concurrent endpoints, missing/stopped VPN,
network/runtime replacement, lock, provider/client death, expiry, streams and files.
A source build or emulator does not prove a production cross-app VPN connection.
Release requires a higher tested versionCode, durable provider/client certificate
enrollment, owner-authorized AP Vault/Zapstore release, and real download/install
and native HTTP/SSE/WS/file cancellation evidence. Do not sign/publish as part of
source implementation.

Android reference: [ContentProvider caller identity](https://developer.android.com/reference/android/content/ContentProvider),
[Network scoped DNS and sockets](https://developer.android.com/reference/android/net/Network).
