# Tower Route Inventory For Wingman App

Status: initial audit
Date: 2026-06-30

## Summary

Tower already has enough Flight Deck PG and storage routes for a read-only Wingman Drive prototype:

- workspace discovery;
- scope and channel listing;
- channel file-folder listing;
- channel file listing;
- file metadata read;
- full file object read as base64 JSON through the Flight Deck PG file object route;
- generic storage object prepare, upload, complete, metadata, and content routes;
- docs listing and doc body read;
- visible workspace event polling and SSE streaming.

It is not yet enough for production-grade Drive write sync:

- no byte-range reads;
- no file delete route;
- no file-folder delete route;
- no first-class file content replacement/version route;
- no optimistic `baseVersion` upload flow for file edits;
- no Drive-specific tree or delta endpoint, only general visible PG events;
- no device-key registration/revocation route confirmed in this audit.

## Source Files Audited

- `wingman-tower/src/routes/flightdeck-pg.ts`
- `wingman-tower/src/routes/storage.ts`
- `wingman-tower/src/services/flightdeck-pg-api.ts`
- `wingman-tower/src/schema/ensure-runtime-schema.ts`

## Workspace, Scope, And Channel Routes

| Route | Status | Auth | Notes For Wingman App |
| --- | --- | --- | --- |
| `GET /api/v4/flightdeck-pg/workspaces` | Present | NIP-98 | Lists typed PG workspaces visible to signer. Good for account bootstrap. |
| `GET /api/v4/flightdeck-pg/workspaces/:workspaceId/descriptor` | Present | NIP-98 | Workspace descriptor and links. Good for config validation. |
| `GET /api/v4/flightdeck-pg/workspaces/:workspaceId/me` | Present | NIP-98 | Actor membership and permissions. Useful for device grant checks. |
| `GET /api/v4/flightdeck-pg/workspaces/:workspaceId/scopes` | Present | NIP-98 | Lists visible scopes. Required for Drive root projection. |
| `GET /api/v4/flightdeck-pg/workspaces/:workspaceId/scopes/:scopeId/channels` | Present | NIP-98 | Lists visible channels for a scope. Required for Drive tree projection. |
| `GET /api/v4/flightdeck-pg/workspaces/:workspaceId/channels/:channelId` | Gap | NIP-98 expected | The CLI/OpenAPI path exists, but the live route lookup returned 404 and only PATCH/DELETE channel routes were found in `flightdeck-pg.ts`. Use the scope channel list as the read path until this is implemented. |

## Event Routes

| Route | Status | Auth | Notes For Wingman App |
| --- | --- | --- | --- |
| `GET /api/v4/flightdeck-pg/workspaces/:workspaceId/events?cursor=` | Present | NIP-98 | Returns visible outbox events ordered by `row_version`; includes refetch routes for files and file folders. Good initial delta source. |
| `GET /api/v4/flightdeck-pg/workspaces/:workspaceId/events/stream` | Present | NIP-98 | SSE stream exists for near-real-time visible events. Useful after polling prototype works. |

Event payloads include `event_type`, `entity_type`, `entity_id`, `operation`, `entity_row_version`, `row_version`, `payload`, and `refetch.route`.

Gap:

- The event feed is general workspace state, not a Drive-specific tree delta. The sync core can start here, but a Drive-specific delta may be useful for efficient large workspaces.

## File Folder Routes

| Route | Status | Auth | Notes For Wingman App |
| --- | --- | --- | --- |
| `GET /api/v4/flightdeck-pg/workspaces/:workspaceId/channels/:channelId/file-folders` | Present | NIP-98 with `file.read` or channel read | Lists folders for a channel. Supports local tree projection. |
| `POST /api/v4/flightdeck-pg/workspaces/:workspaceId/channels/:channelId/file-folders` | Present | NIP-98 with `file.write` or channel write | Creates folder with `title`, optional `parent_folder_id`, and metadata. |
| `GET /api/v4/flightdeck-pg/workspaces/:workspaceId/file-folders/:folderId` | Present | NIP-98 with file/channel read | Reads one folder by ID. |
| `PATCH /api/v4/flightdeck-pg/workspaces/:workspaceId/file-folders/:folderId` | Present | NIP-98 with file/channel write | Updates title, parent, metadata with row version support. |

Folder response includes stable `id`, `workspace_id`, `scope_id`, `channel_id`, `parent_folder_id`, `title`, `metadata`, `row_version`, actors, and timestamps.

Gaps:

- No folder delete/tombstone route found.
- No route found that returns mixed folder plus file children for a parent. Current client must compose folder and file lists.

## File Metadata Routes

| Route | Status | Auth | Notes For Wingman App |
| --- | --- | --- | --- |
| `GET /api/v4/flightdeck-pg/workspaces/:workspaceId/channels/:channelId/files` | Present | NIP-98 with `file.read` or channel read | Lists channel files. Supports online-only placeholders. |
| `POST /api/v4/flightdeck-pg/workspaces/:workspaceId/channels/:channelId/files` | Present | NIP-98 with `file.write` or channel write | Creates file metadata by attaching an existing `storage_object_id`. |
| `GET /api/v4/flightdeck-pg/workspaces/:workspaceId/files/:fileId` | Present | NIP-98 with file/channel read | Reads one file and storage-object metadata. |
| `PATCH /api/v4/flightdeck-pg/workspaces/:workspaceId/files/:fileId` | Present | NIP-98 with file/channel write | Updates channel, folder, display name, description, metadata. Uses row version. |
| `GET /api/v4/flightdeck-pg/workspaces/:workspaceId/files/:fileId/object` | Present | NIP-98 with file/channel read | Returns file metadata plus object content as base64 JSON. |

File response includes stable `id`, `workspace_id`, `scope_id`, `channel_id`, `folder_id`, `storage_object_id`, `display_name`, `description`, `metadata`, `row_version`, actors, timestamps, and an object route.

Gaps:

- No file delete/tombstone route found.
- No file content replacement route found.
- `PATCH /files/:fileId` does not currently accept `storage_object_id`, so content-version replacement is not a first-class file operation.
- No file version list route found.
- `GET /files/:fileId/object` returns full base64 content, not byte ranges.

## Storage Routes

| Route | Status | Auth | Notes For Wingman App |
| --- | --- | --- | --- |
| `POST /api/v4/flightdeck-pg/workspaces/:workspaceId/storage/prepare` | Present | NIP-98 workspace context | Prepares workspace-owned storage object for PG surfaces. Good path for future uploads. |
| `POST /api/v4/storage/prepare` | Present | NIP-98 | Generic storage prepare route. Requires owner and authorization. |
| `GET /api/v4/storage/:objectId` | Present | Public if object public, otherwise NIP-98 | Reads storage object metadata and URLs. |
| `PUT /api/v4/storage/:objectId` | Present | NIP-98 | Writes `base64_data` to object. |
| `POST /api/v4/storage/:objectId/complete` | Present | NIP-98 | Marks object complete and stores size/hash metadata. |
| `GET /api/v4/storage/:objectId/download-url` | Present | Public if object public, otherwise NIP-98 | Returns content/download URL. |
| `GET /api/v4/storage/:objectId/content` | Present | Public if object public, otherwise NIP-98 | Streams full object bytes. |

Gaps:

- No HTTP Range handling found in storage content route.
- Upload path accepts full base64 JSON in the direct route; presigned upload URL may exist depending on storage backend, but Drive should not assume it until tested.
- No object-level optimistic base version for file edits; object write authorization is based on the prepared object's creator/owner, not a file version contract.

## Doc Routes Relevant To Drive

| Route | Status | Auth | Notes For Wingman App |
| --- | --- | --- | --- |
| `GET /api/v4/flightdeck-pg/workspaces/:workspaceId/channels/:channelId/docs` | Present | NIP-98 with doc/channel read | Lists docs in a channel. Useful if Drive chooses to show doc URL entries. |
| `GET /api/v4/flightdeck-pg/workspaces/:workspaceId/docs/:docId` | Present | NIP-98 with doc/channel read | Reads doc metadata and body object metadata. |
| `GET /api/v4/flightdeck-pg/workspaces/:workspaceId/docs/:docId/body` | Present | NIP-98 with doc/channel read | Reads full body as base64 JSON. |
| `GET /api/v4/flightdeck-pg/workspaces/:workspaceId/docs/:docId/versions` | Present | NIP-98 with doc/channel read | Lists doc versions and embeds parsed body content. |

Decision:

- Wingman Drive v1 should expose docs as `.flightdeck.url` entries, not as editable local files. Existing doc routes are enough for optional snapshot/export work later.

## Current Read-Only Prototype Path

The first read-only Drive prototype can use these calls:

1. `GET /workspaces`
2. `GET /workspaces/:workspaceId/scopes`
3. `GET /workspaces/:workspaceId/scopes/:scopeId/channels`
4. For each selected channel:
   - `GET /workspaces/:workspaceId/channels/:channelId/file-folders`
   - `GET /workspaces/:workspaceId/channels/:channelId/files`
   - optionally `GET /workspaces/:workspaceId/channels/:channelId/docs`
5. For lazy open:
   - `GET /workspaces/:workspaceId/files/:fileId/object`
   - or `GET /api/v4/storage/:objectId/content` after resolving authorized object metadata.
6. For changes:
   - `GET /workspaces/:workspaceId/events?cursor=<cursor>`
   - later `GET /workspaces/:workspaceId/events/stream`

## Required Follow-Up Contracts

These gaps should be handled before production desktop write sync:

1. Drive tree/delta endpoint or documented event consumption profile for large workspaces.
2. Byte-range reads for object content.
3. File content replacement/version route with optimistic `baseVersion`.
4. File delete/tombstone route.
5. Folder delete/tombstone route.
6. File version listing route.
7. Single channel read route, or a documented commitment that channel reads are always via scope channel lists.
8. Device key registration, grant, audit, and revocation routes.
9. WApp trusted origin/app identity route for the signer browser.

Phase 1 contract documents:

- `docs/tower_drive_contract.md` defines the target Drive contract.
- `docs/device_key_contract.md` defines the target device-key contract.
- `docs/api_gap_harness.md` defines the smoke harness and follow-up Tower cards.

## Impact On Work Packages

- WP-02-03 can use current Tower routes for a typed read-only client.
- WP-04-01 through WP-04-04 can proceed against current metadata and full-object read routes.
- WP-06-01 through WP-06-03 should not start until versioned file writes and delete/tombstone contracts exist.
- WP-01-02 should define the missing file/folder/version/delta contract from this inventory.
- WP-01-04 should turn the required follow-up contracts into Tower implementation tasks.

## Harness

`tools/tower_drive_smoke.mjs` exercises the current read-only Tower path with NIP-98 signed requests. It is the validation harness for the first native crate's initial Tower client.
