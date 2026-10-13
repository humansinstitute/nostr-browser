# Tower compatibility adapter over universal FIPS transport

This document replaces the retired Tower-specific browser bridge design. The
normative contract is [`fips-browser-transport.md`](fips-browser-transport.md).

WMapp has one browser provider and one native transport engine:
`window.fipsTransport`. Flight Deck obtains immutable endpoint-scoped handles
for Tower and Autopilot independently. TowerSyncService remains the owner of
workspace synchronization, SSE parsing, cursor recovery, polling, hydration,
coalescing and materialisation; the transport only moves bytes to the approved
peer.

During migration, `window.wingmanTowerTransport` is a JavaScript-only adapter.
It calls `window.fipsTransport.connect()` with `purpose: 'tower'`, retains the
returned handle, delegates fetch/worker/disconnect operations, and has no native
channel, proxy listener, pairing store, or transport implementation of its own.
New consumers must not use the adapter. Remove it and its ready event after
Flight Deck no longer references the legacy name.

## Security boundary

- Native main-frame and exact origin checks gate provider injection.
- Consent is per document and exact endpoint; peer identity must match the npub
  encoded by the `.fips` hostname.
- Full navigation, identity change, lock/logout, tab close, browser-data clear,
  and explicit disconnect revoke grants and cancel their resources.
- Requests dial the pinned mesh address directly. Redirect, public HTTPS, DNS,
  proxy, and listener fallbacks are forbidden.
- HTTP response bodies and SSE are pull-driven; uploads, WebSockets, worker
  requests, queues and frames remain bounded and cancellable.
- The transport never signs or authenticates. Flight Deck retains NIP-98,
  installation identity verification, Tower ACL handling and application state.

## Migration and validation

Flight Deck session/thinking streams and Agents pipeline reads should each keep
their own Autopilot handle. Tower synchronization keeps a Tower handle. Drive
and GitWorkshop/GRASP use the same primitive with their own protocol and signer
layers. Multiple approved endpoints may coexist in one document without
replacing a mutable global destination.

Repository validation is provided by:

- `app/test/grasp_fips_transport_test.dart` for pinned HTTP/WebSocket behavior,
  concurrent grants, independent revocation, cancellation and lifecycle rules;
- `app/test/grasp_browser_consent_test.dart` and
  `app/test/tower_mesh_signing_test.dart` for injection and signer separation;
- `tools/grasp_bridge/bridge.test.mjs` for scoped consumer handles and legacy
  adapter delegation.

Live service authentication, Tower/Autopilot deployment state and physical
device behavior remain acceptance checks outside the transport unit tests.
