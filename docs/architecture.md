# Wingman App Architecture

## Universal browser FIPS transport invariant

Every HTTPS/local browser application reaches approved FIPS HTTP, streaming,
SSE and WebSocket services through endpoint-scoped `window.fipsTransport`
handles. Tower, Autopilot, Drive and GRASP/Git do not receive service-specific
browser bridges. Direct `.fips` navigation remains a distinct routing path.
Authentication and protocol verification stay above the transport. See
[`fips-browser-transport.md`](fips-browser-transport.md) for the normative
contract, compatibility window and platform status.

Native transport and authentication consent are distinct, versioned capability
classes scoped to the verified browser origin, device identity, exact service
peer/endpoint/port, and handle purpose. Authentication policy additionally
includes the protocol and operation. A remembered allow is a revocable policy
only; NIP-98 and NIP-42 signatures are freshly generated from each exact request
and cannot outlive or widen the active transport handle.

Status: design draft
Date: 2026-06-30

## Purpose

Wingman App is a native client for the Wingman Be Free platform. It gives a user local access to Tower-backed files, opens Flight Deck and WApps in a trusted browser shell, and signs Nostr/NIP-98 requests from a local per-device key.

The app should feel like a cloud drive plus a secure Wingman browser:

- Files appear locally under workspace, scope, channel, folder, and file.
- File bytes are fetched lazily from Tower over HTTP.
- Flight Deck docs open in the default browser in v1.
- WApps can run inside an embedded browser with a native `window.nostr` signer bridge.
- The private key never enters Flight Deck, WApps, or arbitrary web content.

## Non-Goals

- Do not introduce peer-to-peer sync as an authority path. Tower is the source of truth.
- Do not make SovThing part of the product architecture. It is useful prior art for file transfer and sync UX only.
- Do not build a full bidirectional desktop editor for Flight Deck docs in v1.
- Do not put raw Tower database credentials or S3 credentials in the app.

## Product Surfaces

Wingman App has three connected surfaces.

### Wingman Drive

Projects Tower file metadata into the operating system file surface.

Desktop shape:

```text
~/FlightDeck/
  <Workspace>/
    <Scope>/
      <Channel>/
        <Folder>/
          <File>
```

Mobile shape:

```text
Files app / document picker
  Wingman
    <Workspace>
      <Scope>
        <Channel>
          <Folder>
            <File>
```

### Wingman Browser

An embedded browser for Flight Deck and approved WApps. It injects a browser-extension-style Nostr bridge into allowed origins.

### Wingman Signer

A native key custody layer. It owns per-device Nostr keys, signs NIP-98 requests, and optionally signs approved Nostr events for WApps.

## Authority Model

Tower is the authority for:

- Workspaces.
- User and device key grants.
- Scopes and channels.
- Group membership and access checks.
- File and folder metadata.
- Object content access.
- Version IDs, ETags, tombstones, and conflict decisions.
- WApp assignment and launch visibility.

The app is a local projection and cache. It must not decide durable access rights without Tower verification.

## Planning Documents

The architecture is split across a small set of durable planning documents:

- `docs/architecture.md`: product and system architecture.
- `docs/implementation_plan.md`: phased work packages and execution order.
- `docs/decisions.md`: architecture decision backlog.
- `docs/tower_route_inventory.md`: current Tower API readiness for Wingman Drive and signer work.
- `docs/tower_drive_contract.md`: file, folder, version, tombstone, and delta contract for the sync core.
- `docs/device_key_contract.md`: per-device Nostr key registration, grant, audit, and revocation contract.
- `docs/api_gap_harness.md`: signed API smoke harness and Tower follow-up gap tickets.

## High-Level Architecture

```text
Flutter Shell
  onboarding
  key setup
  sync settings
  tray/status UI
  WApp browser webviews
  permission prompts
          |
          | platform channels / FFI / local control API
          v
Native Core
  Nostr key manager
  NIP-98 signer
  Tower HTTP client
  sync engine
  SQLite metadata index
  object cache
  conflict engine
  platform filesystem adapters
          |
          | NIP-98 HTTP
          v
Tower
  Flight Deck PG APIs
  storage metadata
  file object routes
  group/scope/channel access checks
  S3-compatible object store
```

## Technology Split

Use Flutter for the app shell and native UI. Use a native core, likely Rust, for sync, filesystem, crypto, and long-running daemon work.

Flutter is a good fit for:

- Desktop and mobile UI.
- Onboarding and key import.
- Permission prompts.
- Settings.
- Embedded WebView.
- `window.nostr` bridge UI.
- Sync status and transfer lists.

Rust/native code is a better fit for:

- FUSE/macFUSE filesystem serving.
- Long-running sync daemon behavior.
- SQLite metadata and cache coordination.
- Nostr signing and cryptography.
- Tower HTTP client.
- Range reads and resumable downloads.
- Conflict detection.
- Platform service integration.

The initial Rust workspace now starts at `crates/wmapp-core`. Its first implemented surface is auth: development device-key generation/import and NIP-98 signing. The Tower, sync, cache, SQLite, and control modules are present as crate boundaries for the next Phase 2 work packages.

## Platform Adapters

The shared core should be reused, but the OS integration must be platform-specific.

| Platform | Initial Adapter | Long-Term Adapter | User Experience |
| --- | --- | --- | --- |
| Linux | FUSE | FUSE | Mounted `~/FlightDeck` folder with lazy hydration. |
| macOS | macFUSE | File Provider | Early mounted folder, later Finder-native cloud file behavior. |
| Android | DocumentsProvider | DocumentsProvider | Wingman appears in Android file pickers and document UI. |
| iPhone/iPad | File Provider | File Provider | Wingman appears in the iOS Files app. |

Desktop should feel like a mounted drive. Mobile should feel like a file provider inside the platform file picker or Files app.

## Identity And Key Model

Always use Nostr keys.

The preferred day-to-day model is a per-device Nostr key:

```text
Human identity npub
  owns workspace identity
  can approve/revoke devices

Device npub
  stored locally
  signs NIP-98 requests
  has explicit Tower grants
  can be revoked independently
```

Tower must explicitly map a device npub to the user/workspace grants it can exercise. A device key is still a Nostr key; it is not a separate auth scheme.

Key storage should use platform secure storage where available:

- macOS: Keychain, Secure Enclave where practical.
- Linux: Secret Service/KWallet/libsecret, with a documented encrypted-file fallback.
- Android: Android Keystore.
- iOS: Keychain/Secure Enclave where practical.

## HTTP Auth

The app signs Tower requests with NIP-98. For Tower APIs, the default signed event should be short-lived and scoped to:

- URL.
- HTTP method.
- Payload hash when applicable.
- Timestamp/expiry.
- Device npub.

Tower verifies the signature, resolves the actor and grants, and enforces access server-side.

## File Model

Tower should expose files as metadata records, not only object keys.

Core entities:

- Workspace.
- Scope.
- Channel.
- Folder.
- File.
- File version.
- Tombstone/delete marker.

A file record should include:

- Stable file ID.
- Parent folder/channel/scope IDs.
- Display name.
- MIME type.
- Size.
- Version ID.
- ETag/content hash.
- Modified timestamp.
- Created/modified actor.
- Object reference.
- Access scope.
- Sync flags or server hints where needed.

Folders should be records with stable IDs, not inferred S3 prefixes.

### Current Tower Route Reality

The initial Tower route audit shows that Tower already exposes enough typed PG routes for a read-only Wingman Drive prototype:

- visible workspace, scope, and channel listing;
- channel file-folder listing and creation;
- channel file listing and file metadata creation;
- file metadata read and metadata patch;
- full file-object read as base64 JSON through the Flight Deck PG file object route;
- generic storage object prepare, upload, complete, metadata, and content routes;
- docs listing and doc body read for `.flightdeck.url` or later read-only export behavior;
- visible event polling and SSE streaming.

The audit also found gaps that block production write sync:

- no byte-range reads;
- no file delete/tombstone route;
- no folder delete/tombstone route;
- no first-class file content replacement/version route;
- no optimistic `baseVersion` upload contract for file edits;
- no Drive-specific tree/delta endpoint beyond the general visible event feed;
- no confirmed device-key registration/revocation route.

The detailed inventory lives in `docs/tower_route_inventory.md`.

### Phase 1 Contract Outcome

Phase 1 defines the contract that the first native crate should implement against:

- metadata sync can start with existing scope, channel, file-folder, file, and event routes;
- lazy hydration can start with the current full-object file route;
- write sync must stay feature-gated until Tower adds content version replacement, deletes/tombstones, byte ranges, and base-version conflict checks;
- device auth should be modelled as per-device Nostr keys, with the current workspace-key route treated as prototype-compatible rather than final UX;
- the core should hide Tower route details behind a client boundary so Drive-specific tree and delta routes can replace composed prototype calls later.

## Local Data Model

The app keeps a local SQLite index and object cache.

Suggested local tables:

- `accounts`: Tower base URL, user npub, device npub.
- `workspaces`: visible workspaces.
- `scopes`: visible scopes.
- `channels`: visible channels.
- `items`: folders, files, docs, tombstones.
- `versions`: known remote file versions.
- `cache_entries`: local object paths, byte ranges, pin state.
- `transfers`: queued downloads/uploads.
- `permissions`: per-origin WApp signer grants.
- `sync_cursors`: Tower delta cursors per workspace/scope/channel.

Suggested item states:

- `online_only`: metadata visible, no local bytes.
- `hydrating`: download in progress.
- `hydrated`: local bytes available.
- `pinned`: kept local unless explicitly removed.
- `dirty`: local change not uploaded.
- `uploading`: upload in progress.
- `conflict`: local and remote versions diverged.
- `deleted`: local tombstone pending remote confirmation or remote delete pending local cleanup.

## Sync Semantics

The sync engine should be delta-driven.

Required Tower capabilities:

- List visible workspaces, scopes, and channels.
- List folder/file children by parent.
- Fetch deltas since cursor.
- Fetch object content with range support.
- Upload object content with optimistic base version.
- Create folders.
- Rename/move files and folders.
- Delete or tombstone files and folders.
- Return version IDs and ETags.

Conflict rule:

```text
Upload with baseVersion = localKnownRemoteVersion.
Tower accepts only if currentVersion == baseVersion.
If not, Tower returns conflict and current remote metadata.
```

Local conflict naming:

```text
Report.xlsx
Report (conflict <device-name> 2026-06-30).xlsx
```

## Lazy Hydration

For virtual filesystem reads:

1. The filesystem adapter receives an open/read request.
2. The core checks the cache for the requested range.
3. Missing bytes are fetched from Tower with NIP-98 HTTP.
4. The cache is populated.
5. Bytes are returned to the OS.

Pinned files and folders should hydrate proactively and survive cache eviction. Online-only content can be evicted under disk pressure.

## Flight Deck Docs

For v1, docs are not editable local files.

The file surface should expose docs as URL entries that open the default browser:

```text
Project Brief.flightdeck.url
```

Optional later export:

```text
Project Brief.md
```

The markdown export should be treated as read-only until a deliberate doc edit/reconciliation model exists.

## WApp Browser Signer

The embedded browser injects a NIP-07-style API into approved origins:

```js
await window.nostr.getPublicKey()
await window.nostr.signEvent(event)
await window.nostr.nip44.encrypt(pubkey, plaintext)
await window.nostr.nip44.decrypt(pubkey, ciphertext)
```

The native bridge receives requests, applies local policy, signs or rejects, and returns only the result.

Default safe scope for v1:

- Auto-approve or remember only NIP-98 `kind 27235` signatures for approved Tower/WApp origins.
- Prompt for arbitrary `signEvent`.
- Prompt for NIP-44 decrypt.
- Deny unknown origins by default.

Signer decisions should consider:

- WebView origin.
- WApp ID.
- Workspace ID.
- Scope/channel grants.
- Event kind.
- URL and HTTP method for NIP-98.
- Whether the app was launched from a trusted Wingman WApp record.

## Security Boundaries

The private key must never be exposed to:

- Flight Deck JavaScript.
- WApp JavaScript.
- Arbitrary web pages.
- Tower.
- Object storage.

The app should maintain separate grants for:

- Tower HTTP authentication.
- WApp origin access.
- Event kind signing.
- Encryption/decryption calls.
- File sync scopes/channels.

Revocation must be Tower-driven. If Tower revokes a device key, sync and signer requests should fail closed and cached encrypted material should be purged according to policy.

## Local Control Interface

Flutter can communicate with the native core through platform channels, FFI, or a local control API. A local API is useful for daemon-style operation.

Possible local endpoints:

```text
GET  /status
GET  /accounts
POST /accounts
GET  /mounts
POST /mounts
POST /mounts/:id/unmount
GET  /transfers
POST /items/:id/pin
POST /items/:id/evict
GET  /permissions
PATCH /permissions/:origin
```

The local API should bind to localhost or a Unix domain socket and require a per-install secret if HTTP is used.

## Repository Shape

Planned repo layout:

```text
wm-app/
  docs/
  app/                 # Flutter shell
  core/                # Rust/native shared core
  adapters/
    linux-fuse/
    macos-macfuse/
    macos-fileprovider/
    android-documentsprovider/
    ios-fileprovider/
  crates/              # Rust crates if split from core
  packages/            # Flutter plugins/packages
  fixtures/
  tests/
```

## Open Decisions

- Flutter shell plus Rust core is the current recommendation, but the first prototype should validate WebView injection and FUSE integration before committing to all repo tooling.
- macOS v1 can start with macFUSE for speed, but File Provider is likely the better long-term user experience.
- Device key registration needs a concrete Tower API and UI flow.
- Tower's current file APIs must be audited before finalizing sync endpoints.
- WApp signer policy needs a signed WApp identity model so origin alone is not trusted.
