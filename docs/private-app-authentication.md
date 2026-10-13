# Private app authentication in WMapp

Transport consent is provided only by endpoint-scoped
[`window.fipsTransport`](fips-browser-transport.md) grants. This document covers
the separate authentication/signing layer; approval here never creates or
widens a transport grant.

Open a private app using its link in Flight Deck or Autopilot, then choose the
app's connect/sign-in action. For a directly loaded FIPS app, WMapp derives the
HTTP or relay authentication address from the actual signing request. No FIPS
address needs to be entered in Setup or a Tower pairing dialog.

The native **Approve private app authentication?** dialog shows the requesting
website, full exact target (including scheme, port and path), operation, active
signing identity, and connected service scope when one exists. Choose **Once**
to approve only this request, **Always allow** to remember the exact scoped
service policy, or **Deny**. Website titles and links in chat are not
authenticated app identity. App-list visibility does not grant signing
permission.

**Always allow** remembers consent, never the signed event or Authorization
header. WMapp generates a fresh signature for every exact URL, method, body or
relay challenge. Remembered service consent is keyed by requesting origin,
device identity, exact verified peer endpoint and port, transport purpose,
authentication protocol, and operation. No wildcard port, matching-host
exception, saved transport grant or public fallback is created. Existing signer
deny rules still win. Disconnect, navigation, tab closure, lock/logout, identity
change, or a scope mismatch fails closed even while the policy remains visible
and revocable in the Signer screen.

This direct-app path supports strict FIPS HTTP authentication (kind 27235 or
`signNip98`) and FIPS WebSocket relay authentication (kind 22242). It rejects
ambiguous target tags, URL credentials/fragments, malformed authentication and
non-FIPS destinations. Authentication does not grant repository membership or
change the server's read/write rules.

Flight Deck's Tower and Autopilot handles remain separate and purpose-scoped.
Configured Flight Deck pages may authenticate only to the exact active service
handle that matches the request; they cannot use a direct-app approval or an
approval remembered for another purpose, including after disconnect. GRASP must
not be entered as a Tower or Autopilot endpoint; it is a different service.

The existing personal-WApp signer metadata contract describes future native
identity/discovery integration. The browser does not currently consume those
records as native signing grants. This request-only flow requires no shared
metadata or server change.

Validation:

```sh
cd app
flutter test test/mesh_auth_request_test.dart test/mesh_auth_signing_test.dart test/tower_mesh_signing_test.dart
flutter analyze
```

The widget tests exercise native approval and rejection gates with a fake
WebView and counting signer. A separate case uses the real native signer with
an ephemeral test identity and verifies both HTTP and relay signatures. These
tests do not prove real WebView frame isolation, server authentication or
live-device success. For device acceptance,
install the signed release using the [iPhone build procedure](deploy/iphone.md),
open the private app's existing link, approve its intended HTTP and relay targets,
and verify repository files/history. Repeat with denial and a fresh navigation.
