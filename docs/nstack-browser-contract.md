# NStack Browser Contract v1

Status: implemented foundation
Protocol version: `1`

## Boundary

`window.NStack` is an origin-consented discovery and connection-metadata API.
It is not a network transport, authentication provider, or signer. Applications
use normal HTTPS themselves, use `window.fipsTransport` for approved private
FIPS connections, and request fresh exact NIP-98 signatures through
`window.nostr`. An NStack handle never contains an `nsec`, administrator secret,
bearer token, reusable signature, or browser-wide inventory.

The provider is installed only in a verified top-level HTTPS document or an
approved loopback/local document. Before discovery consent, a document can
observe only that the API exists, `version === 1`, and the result of
`isAvailable()` (`{available: true, version: 1}`). Listing calls fail with
`not_disclosed`.

## JavaScript API

```ts
type NStackErrorCode =
  | "unavailable"
  | "locked"
  | "consent_denied"
  | "not_disclosed"
  | "invalid_request"
  | "stale_handle"
  | "stack_unavailable"
  | "unsupported_capability";

interface NStackError extends Error { code: NStackErrorCode }

interface NStackSummary {
  id: string;       // random, opaque and scoped to origin + signer identity
  name: string;
  host: boolean;
  available: true;
}

interface WorkspaceSummary {
  id: string;       // independently opaque and origin/identity scoped
  name: string;
}

interface CapabilityResult {
  handle: string;   // random, browser-held and document scoped
  stackId: string;
  workspaceId?: string;
  capabilities: string[];
  expiresAt: string;
  connection: {
    transport: "https";
    url: string;
    fipsEndpoint?: string;
    peerNpub?: string;
  };
}

interface WindowNStackV1 {
  readonly version: 1;
  isAvailable(): Promise<{available: true; version: 1}>;
  requestDiscovery(options?: {workspaces?: boolean}): Promise<{
    disclosed: number;
    workspaces: boolean;
  }>;
  listNStacks(): Promise<NStackSummary[]>;
  listWorkspaces(input: {stackId: string}): Promise<WorkspaceSummary[]>;
  requestCapabilities(input: {
    stackId: string;
    workspaceId?: string;
    capabilities: string[];
    duration?: number; // seconds, greater than zero and at most eight hours
  }): Promise<CapabilityResult>;
  revoke(input: {handle: string}): Promise<true>;
  on(name: "change", handler: (event: {reason: string}) => void): () => void;
}
```

Supported v1 capability names are `workspace.read`, `storage.read`,
`storage.write`, `events.read`, and `events.write`. A request containing any
other name fails as a whole with `unsupported_capability`.

## Consent and lifecycle

Discovery opens a native NBrowser selector and persists only the selected
origin rule for the active signer identity. Stack and workspace IDs are fresh
opaque aliases within that origin/identity scope. Discovery is not service
authority.

`requestCapabilities` always opens a distinct approval. An approval creates an
in-memory handle for the current top-level document. The handle is checked
against the calling document, exact origin, active identity, disclosed aliases,
current registry, capability allowlist, and expiry on every operation.

Handles are not persisted or restored. Navigation/document replacement, tab
close, signer lock, identity change, explicit revoke, origin-rule revoke,
registry change, or removal of the underlying stack revokes them. The `change`
listener reports visible changes; callers must re-list and must not treat an
event as authority. NBrowser's NStacks screen lists and revokes persistent
discovery rules and current document handles.

## Error semantics

- `unavailable`: provider/runtime or configured NStack is absent.
- `locked`: the signer is locked or no active identity exists.
- `consent_denied`: the native discovery or capability prompt was declined.
- `not_disclosed`: the origin has no matching disclosure or opaque ID.
- `invalid_request`: malformed fields, empty capabilities, invalid duration, or
  a request that cannot be bound to the verified top-level document.
- `stale_handle`: a handle/document was revoked, expired, or replaced.
- `stack_unavailable`: a previously disclosed stack/workspace was removed.
- `unsupported_capability`: at least one requested capability is outside v1.

Errors reject the Promise with an `Error` whose stable `code` has one of these
values. Messages are explanatory and are not protocol-stable.

## Settings backup and recovery

The versioned settings snapshot includes only the NStack registry and safe
per-stack browser settings (links, launcher background, label colour, and
startup selection). It excludes signer/vault secrets, secure-storage values,
active handles, origin grants, signatures, tokens, browsing sessions, cookies,
cache, and unrelated application settings. Existing identity-scoped v1 browser
links are copied into the first active NStack once and retained in their legacy
record for rollback.

NBrowser self-encrypts the canonical snapshot with NIP-44 v2, then uses Tower's
existing immutable private object flow: signed prepare, signed upload,
hash-checked complete, and signed metadata/content fetch. A signed parameterized
replaceable kind `30078` event uses the stable `d` tag
`org.wingman.nbrowser.settings.v1`. Its NIP-44 self-encrypted content contains
only the host URL, optional workspace identifier, exact object UUID and SHA-256,
snapshot schema/revision/time, and recovery relay URLs.

Recovery accepts only an exactly authored, correctly signed kind-30078 event
with that `d` tag. It decrypts and validates the pointer, retrieves that exact
private object, checks Tower metadata and the downloaded bytes against the
expected hash, decrypts and validates the identity/schema/revision, then shows a
preview. The local registry is a single-record atomic replacement only after
explicit confirmation. Any missing, malformed, stale/conflicting, undecryptable,
or tampered input leaves current settings untouched.

Automated tests use fake storage and relays; they never publish real events.
The manual fixture is [`app/web/nstack-test.html`](../app/web/nstack-test.html).
