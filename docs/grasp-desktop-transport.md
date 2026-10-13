# GRASP/Git profile for the universal FIPS transport

> The provider is now service-neutral. GRASP/Git is one protocol layered over
> the universal [`window.fipsTransport`](fips-browser-transport.md) version-2
> contract, not a distinct browser bridge. Historical `GRASP` names in native
> implementation files and error codes are compatibility identifiers and must
> not be copied into new public contracts.

WMapp iOS, macOS and supported Android WebViews expose `window.fipsTransport` to HTTPS top-level documents after
page load. Register `wingman-fips-transport-ready` before checking availability and
retry initial private-service admission on readiness. Keep the full application UI.

```js
const transport = window.fipsTransport;
const endpoint = 'http://<node-npub>.fips:<port>';
const connection = await transport.connect({endpoint, peerNpub: '<node-npub>', purpose: 'git'});
const info = await connection.fetch(endpoint + '/', {
  headers: {Accept: 'application/nostr+json'}, signal
});
const relay = new connection.WebSocket(endpoint.replace('http:', 'ws:') + '/');
relay.onmessage = ({data}) => handleRelayFrame(JSON.parse(data));
```

Each connection requires native consent for one exact FIPS identity and port. Multiple
endpoint-scoped handles may coexist. No slash suffix,
path, query, credentials or fragment is accepted. Native consent displays the page,
node identity, port and user identity. Announcements propose destinations; they do
not grant authority. The node identity authenticates the mesh peer, not the GRASP
relay pubkey. The app still performs NIP11/GRASP08 classification and membership
checks. This API neither pairs with Tower nor calls Tower health endpoints.

Route only selected-service URLs through the API. Do not change global fetch or
WebSocket, remove CSP, or use public CORS proxies for private traffic. Missing native
transport must be an actionable unavailable state. Native transport has no listener
or DNS fallback: it pins the approved FIPS address and port directly.

`fetch(input, init)` supports Request inputs, GET/HEAD/POST, binary bodies, AbortSignal
and streamed Responses. Status, reason, WWW-Authenticate, content type, Git-Protocol
and safe headers are preserved. Response URL is the original FIPS URL. All redirects
fail without being followed. Cookies, proxy credentials, forwarding headers and
caller Host/Origin are not sent. Upload and download messages use 64 KiB chunks.
Cancellation closes requests before headers and during pending reads.

`new transport.WebSocket(url)` supports open/message/error/close events, property
handlers, readyState constants, send, close, binaryType and bufferedAmount. Text and
binary data are preserved. Only the approved node/port is accepted. Subprotocols and
extensions are not negotiated; redirects and malformed upgrades fail. Payload limit
is 1 MiB, outbound JS queue limit 4 MiB, total native HTTP/opening/socket limit 32.
The frame limit is applied after Dart's parser assembles a frame, not before allocation.
Native sends use a bounded 4 MiB queue and serialized socket backpressure; stalled
sends time out. Revocation/close destroys the socket immediately; client close events
report wasClean=false rather than claiming a completed peer close handshake.

`disconnect()` aborts resources and permits explicit reconnect. Denied endpoints are
not prompted again in that document. Navigation/reload, identity change, lock, tab
close and browser-data clearing revoke grants. Grants are never persisted. Native
frame metadata rejects messages originating in subframes, including same-origin
and opaque sandbox frames. Same-origin code able to execute in the top document
shares that page's authority, as it does elsewhere in the browser.
Async approval, signing and open completion recheck document and identity state.

## Worker HTTP contract

`attachWorker(worker)` transfers `{type:'wingman-grasp-transport-port',port}`. Workers
have no ambient signer or transport. `detachWorker(worker)` aborts before termination.

| Port request | Response |
| --- | --- |
| `{type:'request',id,url,method,headers,bodyBase64:null|string}` | `{type:'headers',id,status,headers:[pairs]}` |
| `{type:'pull',id}` | `{type:'chunk',id,bodyBase64}` or `{type:'end',id}` |
| `{type:'cancel',id}` | Cancels native request |
| Failure/revocation | `{type:'error',id}` |

Worker uploads limit 16 MiB; 64 worker requests maximum, also subject to native limit.
Response chunks require explicit pulls. Keep relay/signing in the main document.
Never forward ports to untrusted workers or frames. Disconnect/detach/revocation
cancel pending worker requests.

## Authentication

Use `window.nostr.signEvent`; transport never signs. GRASP08 private Git expects
kind27235, empty content, tags `[['u',repositoryRoot],['method','GET']]`, timestamp
within 60 seconds. Root is `http://<node-npub>.fips:<port>/<publisher>/<repo>.git`
without trailing slash/query. The app reuses this root GET authorization for info/refs
GET and upload-pack POST. Never rewrite it into Tower per-request authentication.

NIP42 expects kind22242, empty content, exact relay URL and challenge tags. WMapp
requires a challenge received on a currently open approved native socket. Each
signature separately requires exact-request native approval. Consent does not
bypass signer denials, grant arbitrary kinds, or export keys.

## Platform implementations

The Dart HTTP/WebSocket transport is common to iOS, Android and macOS. It
connects to the deterministic mesh address through the platform's active FIPS
route; the computer hosting the static frontend provides no networking authority
to a phone. Private service discovery must await native consent before opening
an announced FIPS relay, including relays from a decrypted private relay list.

- iOS and macOS use the repository-owned WKWebView plugin's shared native
  `WingmanScriptMessagePolicy`. It checks main-frame status, current document
  URL and native security origin for GRASP messages before forwarding to Dart.
- Android installs `WebViewCompat.addWebMessageListener` on the specific WebView,
  checks native main-frame status and source origin against the current URL,
  and requires HTTPS for GRASP. Listener registration is broad enough for browser
  navigation; authorization is enforced by the native origin check and per-document
  grant. The signer and Tower channels use the same native frame checks. No
  privileged `addJavascriptInterface` fallback is installed. Unsupported WebViews
  do not advertise the capability. Installation completes before initial navigation;
  closing the tab removes the listener and revokes resources. Native-generated
  home HTML uses a fixed `https://wingman.local/` base and history URL so Android's
  current URL agrees with its native frame origin; ordinary page policy stays
  unchanged. This preserves home actions without accepting `about:blank` origins.
- Linux has a generated shell and FIPS runtime but no registered embedded WebView
  implementation in this checkout. Web has no native transport; Windows has no
  runner. These targets do not advertise native GRASP support.

The API is available only after page load in an unlocked WMapp with a configured
FIPS preparation callback. Presence means a native transport implementation is
available, not that the service is reachable or the user has approved it. Consumers
must validate version and required methods, handle delayed readiness, and present
unavailable/denied/error separately from an empty repository result. A grant covers
one service; selecting another requires explicit disconnect or a fresh document.

For a GitWorkshop page reporting an incompatible native transport, check the
**installed WMapp build** before diagnosing mesh reachability. GitWorkshop's v2
admission requires `window.fipsTransport.version === 2`, `available === true`,
and a `connect` function. WMapp Setup showing FIPS running checks the local node,
not the WebView bridge contract. An old WMapp build can expose a v1 object and
trigger this error before any service connection is attempted. Install a current
WMapp build, fully quit and reopen it, then reload the GitWorkshop tab. Confirm
that the FIPS consent prompt names the expected HTTPS page and exact private
endpoint and that repository refs, a file, and history load through the approved
connection. A FIPS node inside the server that serves GitWorkshop's static HTTPS
frontend cannot inject `window.fipsTransport` into WMapp or supply the user's
local private peer connection.

## Platform and validation boundary

### Relay diagnosis in an installed macOS app

In **Setup**, explicitly enable **Private relay diagnostics**, then fully quit
and restart WMapp. The switch is off by default; changing it in either direction
does not change recording until the next launch. Setup shows **Restart WMapp to
apply** while the saved setting differs from the setting loaded at launch.

When enabled, the browser bridge writes a bounded, local
`wmapp-relay-diagnostics.jsonl` file
under the app's Application Support directory. For the macOS bundle
`com.wingmanbefree.wmapp`, use Finder's **Go to Folder** with
`~/Library/Application Support/com.wingmanbefree.wmapp/`. The file rotates at
64 KiB to `.previous`. It records UTC time, random document and socket IDs, and
fixed stage names only. It does not contain origins, endpoints, challenges,
signed events, identities, repository data, or frame bodies. Treat the file as
private operational evidence; copy it only to an ignored handoff directory or an
authorized task attachment.

Disabling the switch and restarting prevents new records. Existing trace files
remain until **Clear relay diagnostics** is selected in Setup; this removes both
the current and rotated files. Clearing while recording is enabled may be followed
by new records, so disable and restart first if the goal is to leave no trace.

To diagnose one private relay attempt, fully quit and reopen a build containing
this trace, open the repository once, and collect the file immediately after the
result. The ordered stages distinguish native socket open, relay challenge,
NIP-42 signer request/approval/result, AUTH send/OK, retried REQ, EVENT/EOSE,
socket failure/close, and bridge revocation. An absent signer stage after
`auth_challenge` points to the page or signer routing; a missing `auth_ok` after
`auth_sent` points to relay authentication; EVENT plus EOSE means the browser
transport delivered a complete relay snapshot to page code. This trace alone
does not establish that repository refs, a file, and history rendered.

WebKit's [public registration API](https://developer.apple.com/documentation/webkit/wkwebviewconfiguration/seturlschemehandler(_:forurlscheme:))
cannot register handlers for schemes WebKit owns. Post-load JavaScript replacement
also misses earlier requests and workers. This API needs narrow integration in full
current GitWorkshop; transparent interception of unchanged stock is not claimed.

Run `flutter test` and `flutter analyze` from `app/`, then the available native
builds: `flutter build ios --simulator --debug`, `flutter build macos --debug`,
and `flutter build apk --debug`. Android native origin/lifecycle tests live alongside
the app's Kotlin tests; WebView instrumentation needs an emulator or authorized
test device. An iOS simulator artifact does not validate a physical packet tunnel.
Native probes must use isolated processes and nonpersistent WKWebsiteDataStore,
without touching the user's live app/profile/keychain. Protocol probes and unit tests
prove transport, not full UX. Full acceptance needs the integrated full app, a
consenting member signer, private refs/upload-pack, files and history.
