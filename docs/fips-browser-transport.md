# Universal browser FIPS transport

`window.fipsTransport` is WMapp's single browser capability for an HTTPS
top-level document, or WMapp's bundled loopback Flight Deck origin, to reach an
explicitly approved FIPS service. Direct navigation to a `.fips` WApp is still
handled by WMapp navigation and is not a transport grant.

The provider is injected only after native main-frame origin validation. It is
absent in subframes, non-approved origins and unsupported runtimes. Missing
support is represented by an absent provider
or `available === false`; consumers must never fall back to public HTTP, a CORS
proxy, mixed-content exceptions, or the browser's ambient `fetch`,
`EventSource`, or `WebSocket`.

## Contract (version 2)

```js
const transport = window.fipsTransport;
if (!transport?.available || transport.version < 2) throw new Error('unavailable');

const tower = await transport.connect({
  endpoint: 'http://<fips-node-npub>.fips:8787',
  peerNpub: '<fips-node-npub>',
  purpose: 'tower', // service | tower | autopilot | git | drive
});

const response = await tower.fetch(`${tower.endpoint}/api/...`, {
  method: 'GET',
  headers: { authorization: 'Nostr ...' },
  signal: abortController.signal,
});

const socket = new tower.WebSocket(
  tower.endpoint.replace('http:', 'ws:') + '/relay',
);

await tower.disconnect();
```

`connect()` requires one exact `http://<npub>.fips:<port>` origin. When
`peerNpub` is supplied it must equal the node identity encoded by the hostname.
Native consent shows the calling origin, node, port, and purpose, with **Once**,
**Always allow**, and **Deny** choices. **Always allow** persists only a
versioned transport-policy rule keyed by signer identity, top-level origin,
endpoint, peer, purpose, and transport capability class. A later exact match
may mint a fresh document-scoped handle without prompting; any scope or policy
version change prompts again. It returns an immutable, endpoint-scoped handle
with:

- `grantId`, `endpoint`, `peerNpub`, `purpose`, and `version` metadata;
- `fetch(input, init)` with request-body and response-body streaming and
  `AbortSignal` cancellation;
- `WebSocket`, pinned to the same endpoint with bounded frames and queues;
- `disconnect()`, which revokes only that handle and its native resources.

Up to eight grants may coexist in one document. `transport.fetch()` and
`transport.WebSocket` remain transitional conveniences: they select the unique
grant matching the request URL. New consumers should retain and use the handle
returned by `connect()` so authority is explicit. `transport.disconnect()`
without a handle revokes the entire document; `transport.disconnect(handle)`
revokes one grant.

`fetch()` returns a normal `Response` backed by a pull-driven native stream, so
incremental text decoding and SSE parsers work without `EventSource`. Redirects
are rejected. The native layer allows `GET`, `HEAD`, `POST`, `PUT`, `PATCH`, and
`DELETE`, filters request/response headers, never forwards cookies or a
caller-supplied Host/Origin, dials the peer's derived mesh address directly,
and never uses DNS or a proxy.

`attachWorker(worker)` transfers a `wingman-fips-transport-port`. Requests on
that port use the same grant routing, limits, streaming and cancellation.
`detachWorker(worker)` must run before replacing or terminating a worker.
Document revocation closes all worker ports.

`save(response, options)` remains a provider operation for bounded native
save/export. It consumes the supplied response stream in 64 KiB chunks and does
not grant filesystem paths or service authority to the page.

## Security and lifecycle boundary

The transport does not sign, authenticate a user, prove Tower/Autopilot/GRASP
application identity, or grant application permissions. NIP-98, NIP-42,
installation/service health checks, repository rules and Drive share rules are
consumer protocols layered over an already-approved handle. Signer consent and
transport consent are separate.

For exact-service authentication, the native signer offers **Once**, **Always
allow**, and **Deny**. **Always allow** stores a revocable policy decision, not
a signature. The policy key includes the verified top-level page origin,
current device identity, exact connected endpoint, explicit peer identity and
port, handle purpose, policy version, signing capability class, authentication
protocol, and HTTP/auth operation. Every
accepted call still validates the live handle and exact request, then creates a
fresh NIP-98/NIP-42 signature for the supplied URL, method, body/challenge and
current timestamp. A different page, identity, peer, port, purpose or operation
does not inherit the decision. Navigation, disconnect, lock/logout and tab
teardown make the remembered rule unusable until a matching handle exists
again; the rule stays visible and revocable in the Signer screen.

WMapp revokes the document provider and all grants on full navigation,
cross-origin navigation, tab close, identity change, signer lock/logout, browser
data clearing, or explicit disconnect. Late replies from an older document or
grant cannot reactivate it. Denial is remembered for that document. Unsupported
platform/runtime combinations fail closed.

## Compatibility and Flight Deck migration

During the Flight Deck migration only, WMapp exposes
`window.wingmanTowerTransport` as an adapter over the same
`window.fipsTransport` provider. It has no native channel or network stack of
its own. Its `connect({endpoint, serviceNpub, installationNpub})` maps
`serviceNpub` to `peerNpub`, sets `purpose: 'tower'`, and returns the legacy
connection metadata. `fetch`, worker attachment and `disconnect` delegate to
the resulting handle. `installationNpub` is application metadata; Flight Deck
still owns its authenticated installation health verification.

Flight Deck should migrate each Tower, Autopilot session, pipeline-control,
SSE-worker and sync caller as follows:

1. Feature-detect `window.fipsTransport?.version >= 2`; report unavailable and
   stop if absent.
2. Call `connect()` once per exact Tower or Autopilot endpoint, including the
   endpoint node npub as `peerNpub` and an accurate `purpose`.
3. Retain that returned handle in the owning connection/session object. Do not
   store one mutable global pairing.
4. Replace bridge-global `fetch` with `handle.fetch`; parse SSE incrementally
   from `response.body`, carrying existing cursor/reconnect logic above the
   transport.
5. Use `handle.WebSocket` for endpoint WebSockets and the generic worker port
   for worker-owned HTTP/SSE.
6. Keep NIP-98/NIP-42 signing, advertised installation identity and protocol
   response verification unchanged above the handle.
7. Call `handle.disconnect()` on service/session teardown and
   `detachWorker()` before worker termination.
8. After all references are removed, delete the compatibility adapter and its
   ready event. New code must not wait for `wingman-tower-transport-ready`.

## Platform status

- macOS and iOS use the shared Dart provider plus WKWebView's native main-frame
  origin policy.
- Android uses the same Dart provider and the native WebMessageListener origin
  policy. Failure to install that listener leaves the provider unavailable.
- Linux currently has no supported WebView message-channel implementation in
  this repository. WMapp therefore does not inject the provider on Linux; it
  fails closed. The Linux completion gap is a native, main-frame-origin-checked
  message channel equivalent to the Apple/Android policy, not a transport or
  JavaScript redesign.

Native non-browser features should instantiate the same generic endpoint-pinned
FIPS transport implementation and preserve the same redirect, header, socket,
cancellation and revocation rules. They do not need a JavaScript bridge.
