# Wingman App Decision Backlog

Status: active
Date: 2026-06-30

This document tracks architecture decisions that affect Wingman App work packages. Keep decisions short, evidence-based, and linked to implementation work.

## Decision States

- Open: no implementation should assume the answer is final.
- Proposed: current recommendation is strong enough for a spike.
- Accepted: implementation should follow this unless new evidence appears.
- Superseded: kept for history, but no longer guides implementation.

## ADR-0001: Product Boundary

Status: Accepted
Owner: project maintainer
Related work packages: WP-00-01, WP-00-02

Context:

Wingman App combines three surfaces: Wingman Drive, Wingman Browser, and Wingman Signer. The app must not become a second source of truth for workspace state.

Decision:

Tower remains the authority for workspaces, scopes, channels, groups, files, folders, docs, storage objects, grants, WApps, and audit history. Wingman App is a local projection, cache, and signer.

Consequence:

The native core can cache and index Tower state, but all durable access and mutation decisions must be confirmed by Tower.

## ADR-0002: App Shell And Native Core Split

Status: Proposed
Owner: project maintainer
Related work packages: WP-02-01, WP-03-01

Context:

The app needs cross-platform UI, embedded WebViews, native key custody, long-running sync, and OS file-provider integration.

Decision:

Use Flutter for the user-facing app shell and a native core, likely Rust, for Nostr signing, Tower HTTP, SQLite sync state, object cache, local control API, and desktop filesystem adapters.

Consequence:

Flutter work should not own kernel-facing filesystem behavior. The native core must be testable headlessly before desktop/mobile shell work depends on it.

Finalization trigger:

Accept this after WP-02-01 and WP-03-02 prove the core/shell bridge works on at least one desktop target.

## ADR-0003: Tower Transport And Auth

Status: Accepted
Owner: project maintainer
Related work packages: WP-01-03, WP-02-02, WP-02-03

Context:

Tower is HTTP-enabled and the Wingman platform already uses NIP-98 for signed API access.

Decision:

Wingman App uses NIP-98 signed HTTP requests to Tower. Device identities are Nostr keys. Per-device Nostr keys are preferred over storing a human master key in every app install.

Consequence:

Tower needs explicit device-key registration, grant, and revocation semantics. The device key can be revoked without rotating Owner's main identity.

## ADR-0004: Initial Desktop File Adapter

Status: Proposed
Owner: project maintainer
Related work packages: WP-04-01, WP-05-01, WP-05-03, WP-09-01

Context:

The product target is cloud-drive style lazy file access. macOS File Provider is the polished long-term path, but FUSE/macFUSE is faster for a first shared desktop proof.

Decision:

Implement Linux FUSE first, then macFUSE for early macOS parity. Revisit macOS File Provider after the shared sync model is proven.

Consequence:

The first desktop target should be read-only until Tower has the required versioned write contract.

Finalization trigger:

Accept or revise after WP-05-03 compares macFUSE UX with File Provider requirements.

## ADR-0005: Mobile File Surface

Status: Proposed
Owner: project maintainer
Related work packages: WP-07-02, WP-08-02

Context:

Mobile platforms do not expose the same normal mounted filesystem model as desktop.

Decision:

Use Android DocumentsProvider and iOS File Provider. Mobile should expose Wingman as a document/file provider, not as a desktop-style mounted path.

Consequence:

The shared sync core should represent metadata and content states independently of any one filesystem path model.

## ADR-0006: Flight Deck Docs In Drive

Status: Accepted
Owner: project maintainer
Related work packages: WP-04-04

Context:

Flight Deck docs are structured workspace records backed by storage, comments, versions, and browser behavior. Bidirectional local editing would need a deliberate reconciliation model.

Decision:

For v1, expose docs in Drive as `.flightdeck.url` entries that open the default browser. Optional markdown export can come later and should be read-only until an edit model is designed.

Consequence:

Drive work should not block on doc edit semantics.

## ADR-0007: WApp Browser Signer

Status: Proposed
Owner: project maintainer
Related work packages: WP-03-03, WP-03-04, WP-10-01, WP-10-02

Context:

Keychat demonstrates the useful pattern: a native key holder plus embedded browser with a `window.nostr` bridge. Wingman wants that pattern without forking Keychat or adopting the chat stack.

Decision:

Wingman Browser injects a NIP-07-style `window.nostr` bridge only for trusted WApp/Flight Deck origins. The native app signs or denies requests after applying local policy.

Consequence:

Default safe approval is limited to NIP-98 `kind 27235` requests for trusted Tower/WApp origins. Arbitrary `signEvent` and decrypt requests require explicit approval.

Finalization trigger:

Accept after WP-03-04 proves the prompt flow and WP-10-01 defines trusted WApp identity.

## ADR-0008: Tower Route Readiness For Drive

Status: Accepted
Owner: project maintainer
Related work packages: WP-01-01, WP-01-02, WP-01-04

Context:

Tower already exposes several PG file, folder, storage, and event routes, but the route inventory found missing drive-grade capabilities.

Decision:

Treat current Tower routes as sufficient for read-only metadata listing and full-object hydration experiments, but not sufficient for production Drive write support.

Consequence:

WP-02 and WP-04 can proceed against existing routes for read-only prototypes. WP-06 must wait for versioned content replacement, deletes, and conflict-safe write contracts.

Evidence:

WP-01-02 defines the missing file/folder/version/delta contract in `docs/tower_drive_contract.md`. WP-01-04 defines the signed harness and turns missing Tower capabilities into `WMAPP TOWER-GAP-*` follow-up cards.

## ADR-0009: First Crate Tower Contract

Status: Accepted
Owner: project maintainer
Related work packages: WP-01-02, WP-01-03, WP-01-04, WP-02-01, WP-02-03

Context:

The first native crate needs stable boundaries before Tower has every production Drive route.

Decision:

Implement the first crate against a read-first Tower client boundary:

- list workspaces, scopes, channels, folders, files, and events through current Tower routes;
- hydrate file content through the current full-object file route;
- model write methods in the interface but return an unsupported contract error until Tower adds versioned writes, tombstones, and range reads;
- model auth as per-device Nostr keys even when local development uses an existing workspace/agent key.

Consequence:

WP-02 can start without waiting for Tower write-sync gaps, but it must not accidentally promise production bidirectional sync.
