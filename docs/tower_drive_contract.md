# Tower Drive Contract

Status: phase 1 draft
Date: 2026-06-30
Related work package: WP-01-02

## Purpose

This contract defines the Tower API shape required by Wingman Drive. The first native crate should code to these concepts even when the current Tower route is still a prototype path.

Tower remains the source of truth. Wingman App stores a local projection and cache only.

## Current Implementation Baseline

The current Tower routes are enough for read-only listing and full-object hydration:

- list workspaces, scopes, and scope channels;
- list channel file folders;
- list channel files;
- read one file metadata record;
- read one file object as full base64 JSON;
- prepare, upload, complete, and read generic storage objects;
- poll visible workspace events.

These routes are not enough for production write sync because file content replacement, byte ranges, deletes, tombstones, and a Drive-specific delta profile are not yet first-class.

## Core Entities

### Workspace

Required fields:

- `id`
- `workspace_owner_npub`
- `app_npub`
- `name`
- `row_version`

### Scope

Required fields:

- `id`
- `workspace_id`
- `name`
- `row_version`

### Channel

Required fields:

- `id`
- `workspace_id`
- `scope_id`
- `name`
- `row_version`

The sync core should load channels through `GET /workspaces/:workspaceId/scopes/:scopeId/channels` until a single-channel read route is confirmed.

### Folder

Required fields:

- `id`
- `workspace_id`
- `scope_id`
- `channel_id`
- `parent_folder_id`
- `title`
- `metadata`
- `row_version`
- `created_at`
- `updated_at`
- `created_by_actor_id`
- `updated_by_actor_id`
- `deleted_at` or equivalent tombstone field, once implemented

Folders must be stable records. They must not be inferred from S3 prefixes.

### File

Required fields:

- `id`
- `workspace_id`
- `scope_id`
- `channel_id`
- `folder_id`
- `display_name`
- `description`
- `metadata`
- `row_version`
- `created_at`
- `updated_at`
- `created_by_actor_id`
- `updated_by_actor_id`
- `current_version_id`
- `storage_object_id`
- `size_bytes`
- `content_type`
- `sha256_hex`
- `etag`
- `deleted_at` or equivalent tombstone field, once implemented

The current Tower file response exposes `storage_object_id`, `row_version`, folder placement, names, and an object route. The version/content fields above are the contract for Drive-grade sync.

### File Version

Required fields:

- `id`
- `workspace_id`
- `file_id`
- `version_number` or monotonic `row_version`
- `storage_object_id`
- `size_bytes`
- `content_type`
- `sha256_hex`
- `etag`
- `created_at`
- `created_by_actor_id`
- `base_version_id`
- `operation`: `created`, `replaced`, `deleted`, or `restored`

Version records allow the local sync core to tell the difference between metadata edits, content edits, deletes, and conflict branches.

### Tombstone

Required fields:

- `entity_type`: `file` or `folder`
- `entity_id`
- `workspace_id`
- `scope_id`
- `channel_id`
- `parent_folder_id`
- `name`
- `row_version`
- `deleted_at`
- `deleted_by_actor_id`

Deletes must be durable enough that an offline client can observe them through a later delta pass.

## Required Routes

### Read Tree

Prototype route:

```http
GET /api/v4/flightdeck-pg/workspaces/:workspaceId/channels/:channelId/file-folders
GET /api/v4/flightdeck-pg/workspaces/:workspaceId/channels/:channelId/files
```

Drive-grade route:

```http
GET /api/v4/flightdeck-pg/workspaces/:workspaceId/drive/tree?scope_id=&channel_id=&parent_folder_id=&cursor=
```

Response:

```json
{
  "items": [
    { "type": "folder", "id": "folder-id", "row_version": 12 },
    { "type": "file", "id": "file-id", "row_version": 44, "current_version_id": "version-id" }
  ],
  "next_cursor": "opaque-or-null"
}
```

The first crate can compose the prototype file and folder routes. It should isolate that composition behind a `TowerDriveClient.listChildren` style boundary.

### Read Content

Prototype route:

```http
GET /api/v4/flightdeck-pg/workspaces/:workspaceId/files/:fileId/object
```

Drive-grade route:

```http
GET /api/v4/flightdeck-pg/workspaces/:workspaceId/files/:fileId/versions/:versionId/content
Range: bytes=0-1048575
```

Required behavior:

- support HTTP `Range`;
- return `ETag`;
- return `Accept-Ranges: bytes`;
- fail with `404` when the file or version is not visible;
- fail with `409` when content upload is incomplete;
- fail with `410` when the version is tombstoned and no content exists.

### Create File

Current prototype flow:

1. `POST /api/v4/flightdeck-pg/workspaces/:workspaceId/storage/prepare`
2. `PUT /api/v4/storage/:objectId`
3. `POST /api/v4/storage/:objectId/complete`
4. `POST /api/v4/flightdeck-pg/workspaces/:workspaceId/channels/:channelId/files`

Drive-grade route:

```http
POST /api/v4/flightdeck-pg/workspaces/:workspaceId/drive/files
```

Request:

```json
{
  "channel_id": "channel-id",
  "folder_id": "folder-id-or-null",
  "display_name": "report.pdf",
  "storage_object_id": "object-id",
  "base_version_id": null,
  "client_mutation_id": "uuid"
}
```

### Replace File Content

Required route:

```http
POST /api/v4/flightdeck-pg/workspaces/:workspaceId/files/:fileId/versions
```

Request:

```json
{
  "base_version_id": "current-version-id",
  "storage_object_id": "new-object-id",
  "client_mutation_id": "uuid"
}
```

Conflict behavior:

- return `201` with the new version when `base_version_id` is current;
- return `409 stale_base_version` with current file/version metadata when the client is behind;
- never silently replace content when the base version is stale.

### Move Or Rename

Current prototype route:

```http
PATCH /api/v4/flightdeck-pg/workspaces/:workspaceId/files/:fileId
```

Required request fields:

- `row_version`
- `display_name`
- `folder_id`
- `channel_id`

Conflict behavior:

- return `409 stale_row_version` if metadata changed since the client read it.

### Delete File

Required route:

```http
DELETE /api/v4/flightdeck-pg/workspaces/:workspaceId/files/:fileId
```

Request:

```json
{
  "row_version": 44,
  "client_mutation_id": "uuid"
}
```

Required behavior:

- create a file tombstone;
- emit a visible event with `operation: deleted`;
- leave prior versions auditable;
- deny if the caller lacks `file.write` or channel write permission.

### Delete Folder

Required route:

```http
DELETE /api/v4/flightdeck-pg/workspaces/:workspaceId/file-folders/:folderId
```

Request:

```json
{
  "row_version": 12,
  "mode": "empty-only",
  "client_mutation_id": "uuid"
}
```

Required behavior:

- default to `empty-only` deletes for v1;
- return `409 folder_not_empty` if children exist;
- emit a visible event with `operation: deleted`.

### Delta

Prototype route:

```http
GET /api/v4/flightdeck-pg/workspaces/:workspaceId/events?cursor=
```

Drive-grade route:

```http
GET /api/v4/flightdeck-pg/workspaces/:workspaceId/drive/delta?cursor=&scope_id=&channel_id=
```

Response:

```json
{
  "changes": [
    {
      "type": "file",
      "id": "file-id",
      "operation": "updated",
      "row_version": 45,
      "refetch": "/api/v4/flightdeck-pg/workspaces/workspace-id/files/file-id"
    }
  ],
  "next_cursor": "opaque",
  "has_more": false
}
```

The first crate should support the existing general event route first and keep the delta consumer abstract enough to swap in the Drive route later.

## Local Sync States

The sync core should represent each item with one of these states:

- `online_only`: metadata exists locally, content is not cached.
- `hydrating`: content fetch is active.
- `cached`: content exists locally but is evictable.
- `pinned`: content exists locally and should survive normal eviction.
- `dirty`: local change has not been uploaded.
- `conflicted`: local change could not be applied because the Tower base version changed.
- `deleted`: tombstone observed; local path should disappear after OS adapter acknowledgement.

## First Crate Boundary

The first native crate should expose a Tower client with these methods:

- `list_workspaces`
- `list_scopes`
- `list_channels`
- `list_children`
- `get_file`
- `get_file_content`
- `poll_events`

Write methods should exist as traits/interfaces but can return `UnsupportedByTowerContract` until the Tower gap tasks land.
