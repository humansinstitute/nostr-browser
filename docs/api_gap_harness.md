# API Gap Harness And Tower Tickets

Status: phase 1 draft
Date: 2026-06-30
Related work package: WP-01-04

## Purpose

This document describes the signed smoke-test flow for the current Tower API and records the explicit Tower follow-up work needed before Wingman Drive can support production write sync.

## Smoke Harness

Script:

```bash
tools/tower_drive_smoke.mjs
```

Environment:

```bash
export TOWER_URL="http://127.0.0.1:3100"
export FLIGHTDECK_APP_NPUB="<verified-app-npub>"
export WINGMAN_NSEC="<hex-or-nsec-device-or-agent-key>"
```

Basic read-only smoke:

```bash
tools/tower_drive_smoke.mjs \
  --workspace-id 00000000-0000-4000-8000-000000000001 \
  --scope-id __pg_channel__:00000000-0000-4000-8000-000000000002 \
  --channel-id 00000000-0000-4000-8000-000000000002
```

Full-object hydration smoke:

```bash
tools/tower_drive_smoke.mjs \
  --workspace-id <workspace-id> \
  --channel-id <channel-id> \
  --file-id <file-id>
```

The harness signs every request with NIP-98 and checks:

- workspace discovery;
- workspace descriptor;
- workspace membership and permissions;
- scope listing;
- channel listing when a scope is supplied;
- folder listing when a channel is supplied;
- file listing when a channel is supplied;
- general event polling from cursor `0`;
- full file object read when a file is supplied.

## Expected Result

For an authorized signer, the script should print a JSON summary like:

```json
{
  "ok": true,
  "checks": [
    { "name": "workspaces", "ok": true },
    { "name": "files", "ok": true, "count": 2 }
  ]
}
```

For an unauthorized signer, failures should be explicit and should include the failing route and HTTP status.

## Current Known Gaps

These gaps block production write sync:

1. Drive tree/delta endpoint or documented event profile.
2. Byte-range reads for file content.
3. File content replacement/version route with optimistic base version.
4. File delete/tombstone route.
5. Folder delete/tombstone route.
6. File version list route.
7. Single channel read route or a documented decision to use scope channel lists only.
8. First-class device key registration, listing, audit, and revocation routes.
9. Trusted WApp origin/app identity route for the embedded signer.

## Tower Follow-Up Tickets

The Flight Deck board contains explicit follow-up cards for:

- `WMAPP TOWER-GAP-01: Drive Tree And Delta Contract`
- `WMAPP TOWER-GAP-02: Byte Range File Content Reads`
- `WMAPP TOWER-GAP-03: File Version Replacement With Base Version`
- `WMAPP TOWER-GAP-04: File And Folder Tombstones`
- `WMAPP TOWER-GAP-05: File Version Listing`
- `WMAPP TOWER-GAP-06: Single Channel Read Or Contracted Alternative`
- `WMAPP TOWER-GAP-07: Device Key Lifecycle Routes`
- `WMAPP TOWER-GAP-08: Trusted WApp Origin Identity`

## First Crate Readiness

The first native crate can start after Phase 1 using these assumptions:

- implement read-only metadata sync against existing Tower routes;
- implement lazy full-object hydration through the current file object route;
- implement event polling against the existing general event route;
- keep write sync behind explicit unsupported errors until Tower gap cards land;
- model device keys as Nostr keys, even if local development uses an existing agent key.
