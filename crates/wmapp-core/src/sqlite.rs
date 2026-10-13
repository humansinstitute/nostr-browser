use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{named_params, params, Connection, OptionalExtension};
use serde::Serialize;
use serde_json::Value;
use thiserror::Error;

use crate::tower::{
    Channel, DriveChange, DriveItemType, DriveTreeItem, FileMetadata, FileObjectMetadata, Scope,
    WorkspaceDescriptor, WorkspaceMeResponse, WorkspaceSummary,
};

const SCHEMA_VERSION: u32 = 1;

#[derive(Debug, Error)]
pub enum SqliteIndexError {
    #[error("SQLite error: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("serialization error: {0}")]
    Serde(#[from] serde_json::Error),
    #[error("invalid cache path outside cache root")]
    InvalidCachePath,
}

#[derive(Debug, Clone)]
pub struct SqliteIndexConfig {
    pub path: PathBuf,
}

#[derive(Debug)]
pub struct SqliteIndex {
    path: PathBuf,
    conn: Connection,
}

impl SqliteIndex {
    pub fn open(config: SqliteIndexConfig) -> Result<Self, SqliteIndexError> {
        let conn = Connection::open(&config.path)?;
        let index = Self {
            path: config.path,
            conn,
        };
        index.migrate()?;
        Ok(index)
    }

    pub fn open_in_memory() -> Result<Self, SqliteIndexError> {
        let conn = Connection::open_in_memory()?;
        let index = Self {
            path: PathBuf::from(":memory:"),
            conn,
        };
        index.migrate()?;
        Ok(index)
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn schema_version(&self) -> Result<u32, SqliteIndexError> {
        let version = self.conn.query_row(
            "SELECT version FROM schema_migrations ORDER BY version DESC LIMIT 1",
            [],
            |row| row.get::<_, u32>(0),
        )?;
        Ok(version)
    }

    pub fn upsert_workspace_summary(
        &self,
        workspace: &WorkspaceSummary,
    ) -> Result<(), SqliteIndexError> {
        let workspace_id = workspace.identity.workspace_id.as_deref().unwrap_or("");
        self.conn.execute(
            "INSERT INTO workspaces (
                id, label, slug, description, avatar_url, tower_base_url, row_version,
                metadata_json, identity_json, descriptor_json, updated_at, synced_at
             ) VALUES (
                :id, :label, :slug, :description, :avatar_url, :tower_base_url, NULL,
                :metadata_json, :identity_json, NULL, :updated_at, :synced_at
             )
             ON CONFLICT(id) DO UPDATE SET
                label = excluded.label,
                slug = excluded.slug,
                description = excluded.description,
                avatar_url = excluded.avatar_url,
                tower_base_url = excluded.tower_base_url,
                metadata_json = excluded.metadata_json,
                identity_json = excluded.identity_json,
                updated_at = excluded.updated_at,
                synced_at = excluded.synced_at",
            named_params! {
                ":id": workspace_id,
                ":label": workspace.label,
                ":slug": workspace.slug,
                ":description": workspace.description,
                ":avatar_url": workspace.avatar_url,
                ":tower_base_url": workspace.tower_base_url,
                ":metadata_json": json_text(&workspace.metadata)?,
                ":identity_json": json_text(&workspace.identity)?,
                ":updated_at": workspace.created_at,
                ":synced_at": now_ms(),
            },
        )?;
        Ok(())
    }

    pub fn upsert_workspace_descriptor(
        &self,
        descriptor: &WorkspaceDescriptor,
    ) -> Result<(), SqliteIndexError> {
        let workspace_id = descriptor.identity.workspace_id.as_deref().unwrap_or("");
        self.conn.execute(
            "INSERT INTO workspaces (
                id, label, slug, description, avatar_url, tower_base_url, row_version,
                metadata_json, identity_json, descriptor_json, updated_at, synced_at
             ) VALUES (
                :id, :label, :slug, :description, :avatar_url, :tower_base_url, :row_version,
                :metadata_json, :identity_json, :descriptor_json, :updated_at, :synced_at
             )
             ON CONFLICT(id) DO UPDATE SET
                label = excluded.label,
                slug = excluded.slug,
                description = excluded.description,
                avatar_url = excluded.avatar_url,
                tower_base_url = excluded.tower_base_url,
                row_version = excluded.row_version,
                metadata_json = excluded.metadata_json,
                identity_json = excluded.identity_json,
                descriptor_json = excluded.descriptor_json,
                updated_at = excluded.updated_at,
                synced_at = excluded.synced_at",
            named_params! {
                ":id": workspace_id,
                ":label": descriptor.label,
                ":slug": descriptor.slug,
                ":description": descriptor.description,
                ":avatar_url": descriptor.avatar_url,
                ":tower_base_url": descriptor.tower_base_url,
                ":row_version": descriptor.version,
                ":metadata_json": json_text(&descriptor.metadata)?,
                ":identity_json": json_text(&descriptor.identity)?,
                ":descriptor_json": json_text(descriptor)?,
                ":updated_at": descriptor.created_at,
                ":synced_at": now_ms(),
            },
        )?;
        Ok(())
    }

    pub fn upsert_workspace_permissions(
        &self,
        workspace_id: &str,
        me: &WorkspaceMeResponse,
    ) -> Result<usize, SqliteIndexError> {
        self.conn.execute(
            "INSERT INTO accounts (
                signer_npub, actor_id, actor_npub, actor_kind, display_name,
                workspace_id, membership_role, permissions_json, visible_json, synced_at
             ) VALUES (
                :signer_npub, :actor_id, :actor_npub, :actor_kind, :display_name,
                :workspace_id, :membership_role, :permissions_json, :visible_json, :synced_at
             )
             ON CONFLICT(signer_npub, workspace_id) DO UPDATE SET
                actor_id = excluded.actor_id,
                actor_npub = excluded.actor_npub,
                actor_kind = excluded.actor_kind,
                display_name = excluded.display_name,
                membership_role = excluded.membership_role,
                permissions_json = excluded.permissions_json,
                visible_json = excluded.visible_json,
                synced_at = excluded.synced_at",
            named_params! {
                ":signer_npub": me.actor.npub,
                ":actor_id": me.actor.actor_id,
                ":actor_npub": me.actor.npub,
                ":actor_kind": me.actor.kind,
                ":display_name": me.actor.display_name,
                ":workspace_id": workspace_id,
                ":membership_role": me.membership.role,
                ":permissions_json": json_text(&me.permissions)?,
                ":visible_json": json_text(&me.visible)?,
                ":synced_at": now_ms(),
            },
        )?;

        let mut count = 0;
        for permission in &me.permissions {
            self.conn.execute(
                "INSERT INTO permissions (
                    workspace_id, principal_npub, permission, source_json, synced_at
                 ) VALUES (
                    :workspace_id, :principal_npub, :permission, :source_json, :synced_at
                 )
                 ON CONFLICT(workspace_id, principal_npub, permission) DO UPDATE SET
                    source_json = excluded.source_json,
                    synced_at = excluded.synced_at",
                named_params! {
                    ":workspace_id": workspace_id,
                    ":principal_npub": me.actor.npub,
                    ":permission": permission,
                    ":source_json": json_text(me)?,
                    ":synced_at": now_ms(),
                },
            )?;
            count += 1;
        }
        Ok(count)
    }

    pub fn upsert_scope(&self, scope: &Scope) -> Result<(), SqliteIndexError> {
        self.conn.execute(
            "INSERT INTO scopes (
                id, workspace_id, name, description, kind, owner_actor_id, owner_group_id,
                default_channel_id, row_version, created_at, updated_at, source_json, synced_at
             ) VALUES (
                :id, :workspace_id, :name, :description, :kind, :owner_actor_id, :owner_group_id,
                :default_channel_id, :row_version, :created_at, :updated_at, :source_json, :synced_at
             )
             ON CONFLICT(id) DO UPDATE SET
                workspace_id = excluded.workspace_id,
                name = excluded.name,
                description = excluded.description,
                kind = excluded.kind,
                owner_actor_id = excluded.owner_actor_id,
                owner_group_id = excluded.owner_group_id,
                default_channel_id = excluded.default_channel_id,
                row_version = excluded.row_version,
                created_at = excluded.created_at,
                updated_at = excluded.updated_at,
                source_json = excluded.source_json,
                synced_at = excluded.synced_at",
            named_params! {
                ":id": scope.id,
                ":workspace_id": scope.workspace_id,
                ":name": scope.name,
                ":description": scope.description,
                ":kind": scope.kind,
                ":owner_actor_id": scope.owner_actor_id,
                ":owner_group_id": scope.owner_group_id,
                ":default_channel_id": scope.default_channel_id,
                ":row_version": scope.row_version,
                ":created_at": scope.created_at,
                ":updated_at": scope.updated_at,
                ":source_json": json_text(scope)?,
                ":synced_at": now_ms(),
            },
        )?;
        Ok(())
    }

    pub fn upsert_channel(&self, channel: &Channel) -> Result<(), SqliteIndexError> {
        self.conn.execute(
            "INSERT INTO channels (
                id, workspace_id, scope_id, name, description, kind, participant_npubs_json,
                metadata_json, row_version, created_at, updated_at, source_json, synced_at
             ) VALUES (
                :id, :workspace_id, :scope_id, :name, :description, :kind, :participant_npubs_json,
                :metadata_json, :row_version, :created_at, :updated_at, :source_json, :synced_at
             )
             ON CONFLICT(id) DO UPDATE SET
                workspace_id = excluded.workspace_id,
                scope_id = excluded.scope_id,
                name = excluded.name,
                description = excluded.description,
                kind = excluded.kind,
                participant_npubs_json = excluded.participant_npubs_json,
                metadata_json = excluded.metadata_json,
                row_version = excluded.row_version,
                created_at = excluded.created_at,
                updated_at = excluded.updated_at,
                source_json = excluded.source_json,
                synced_at = excluded.synced_at",
            named_params! {
                ":id": channel.id,
                ":workspace_id": channel.workspace_id,
                ":scope_id": channel.scope_id,
                ":name": channel.name,
                ":description": channel.description,
                ":kind": channel.kind,
                ":participant_npubs_json": json_text(&channel.participant_npubs)?,
                ":metadata_json": json_text(&channel.metadata)?,
                ":row_version": channel.row_version,
                ":created_at": channel.created_at,
                ":updated_at": channel.updated_at,
                ":source_json": json_text(channel)?,
                ":synced_at": now_ms(),
            },
        )?;
        Ok(())
    }

    pub fn upsert_drive_item(&self, item: &DriveTreeItem) -> Result<(), SqliteIndexError> {
        let item_type = match item.item_type {
            DriveItemType::File => "file",
            DriveItemType::Folder => "folder",
        };
        self.conn.execute(
            "INSERT INTO items (
                id, item_type, workspace_id, scope_id, channel_id, parent_folder_id, name,
                current_version_id, storage_object_id, row_version, local_state, updated_at,
                source_json, synced_at
             ) VALUES (
                :id, :item_type, :workspace_id, :scope_id, :channel_id, :parent_folder_id, :name,
                :current_version_id, :storage_object_id, :row_version, 'online_only', :updated_at,
                :source_json, :synced_at
             )
             ON CONFLICT(id) DO UPDATE SET
                item_type = excluded.item_type,
                workspace_id = excluded.workspace_id,
                scope_id = excluded.scope_id,
                channel_id = excluded.channel_id,
                parent_folder_id = excluded.parent_folder_id,
                name = excluded.name,
                current_version_id = excluded.current_version_id,
                storage_object_id = excluded.storage_object_id,
                row_version = excluded.row_version,
                updated_at = excluded.updated_at,
                source_json = excluded.source_json,
                synced_at = excluded.synced_at",
            named_params! {
                ":id": item.id,
                ":item_type": item_type,
                ":workspace_id": item.workspace_id,
                ":scope_id": item.scope_id,
                ":channel_id": item.channel_id,
                ":parent_folder_id": item.parent_folder_id,
                ":name": item.name,
                ":current_version_id": item.current_version_id,
                ":storage_object_id": item.storage_object_id,
                ":row_version": item.row_version,
                ":updated_at": item.updated_at,
                ":source_json": json_text(item)?,
                ":synced_at": now_ms(),
            },
        )?;
        self.upsert_drive_version(item)?;
        Ok(())
    }

    pub fn upsert_file_metadata(&self, file: &FileMetadata) -> Result<(), SqliteIndexError> {
        self.conn.execute(
            "INSERT INTO items (
                id, item_type, workspace_id, scope_id, channel_id, parent_folder_id, name,
                current_version_id, storage_object_id, row_version, metadata_json, local_state,
                created_at, updated_at, created_by_actor_id, updated_by_actor_id, source_json, synced_at
             ) VALUES (
                :id, 'file', :workspace_id, :scope_id, :channel_id, :parent_folder_id, :name,
                :current_version_id, :storage_object_id, :row_version, :metadata_json, 'online_only',
                :created_at, :updated_at, :created_by_actor_id, :updated_by_actor_id, :source_json, :synced_at
             )
             ON CONFLICT(id) DO UPDATE SET
                workspace_id = excluded.workspace_id,
                scope_id = excluded.scope_id,
                channel_id = excluded.channel_id,
                parent_folder_id = excluded.parent_folder_id,
                name = excluded.name,
                current_version_id = excluded.current_version_id,
                storage_object_id = excluded.storage_object_id,
                row_version = excluded.row_version,
                metadata_json = excluded.metadata_json,
                created_at = excluded.created_at,
                updated_at = excluded.updated_at,
                created_by_actor_id = excluded.created_by_actor_id,
                updated_by_actor_id = excluded.updated_by_actor_id,
                source_json = excluded.source_json,
                synced_at = excluded.synced_at",
            named_params! {
                ":id": file.id,
                ":workspace_id": file.workspace_id,
                ":scope_id": file.scope_id,
                ":channel_id": file.channel_id,
                ":parent_folder_id": file.folder_id,
                ":name": file.display_name,
                ":current_version_id": file.current_version_id,
                ":storage_object_id": file.storage_object_id,
                ":row_version": file.row_version,
                ":metadata_json": json_text(&file.metadata)?,
                ":created_at": file.created_at,
                ":updated_at": file.updated_at,
                ":created_by_actor_id": file.created_by_actor_id,
                ":updated_by_actor_id": file.updated_by_actor_id,
                ":source_json": json_text(file)?,
                ":synced_at": now_ms(),
            },
        )?;
        Ok(())
    }

    pub fn upsert_file_object_metadata(
        &self,
        file: &FileMetadata,
        object: &FileObjectMetadata,
    ) -> Result<(), SqliteIndexError> {
        self.upsert_file_metadata(file)?;
        let version_id = file
            .current_version_id
            .as_deref()
            .unwrap_or(object.object_id.as_str());
        self.conn.execute(
            "INSERT INTO versions (
                id, workspace_id, file_id, storage_object_id, size_bytes, content_type,
                sha256_hex, etag, created_at, created_by_actor_id, source_json, synced_at
             ) VALUES (
                :id, :workspace_id, :file_id, :storage_object_id, :size_bytes, :content_type,
                :sha256_hex, NULL, :created_at, :created_by_actor_id, :source_json, :synced_at
             )
             ON CONFLICT(id) DO UPDATE SET
                workspace_id = excluded.workspace_id,
                file_id = excluded.file_id,
                storage_object_id = excluded.storage_object_id,
                size_bytes = excluded.size_bytes,
                content_type = excluded.content_type,
                sha256_hex = excluded.sha256_hex,
                created_at = excluded.created_at,
                created_by_actor_id = excluded.created_by_actor_id,
                source_json = excluded.source_json,
                synced_at = excluded.synced_at",
            named_params! {
                ":id": version_id,
                ":workspace_id": file.workspace_id,
                ":file_id": file.id,
                ":storage_object_id": object.object_id,
                ":size_bytes": object.size_bytes,
                ":content_type": object.content_type,
                ":sha256_hex": object.sha256_hex,
                ":created_at": file.updated_at.as_ref().or(file.created_at.as_ref()),
                ":created_by_actor_id": file.updated_by_actor_id.as_ref().or(file.created_by_actor_id.as_ref()),
                ":source_json": json_text(object)?,
                ":synced_at": now_ms(),
            },
        )?;
        Ok(())
    }

    pub fn mark_item_cached(
        &self,
        file_id: &str,
        storage_object_id: &str,
    ) -> Result<(), SqliteIndexError> {
        self.conn.execute(
            "UPDATE items SET local_state = 'cached', storage_object_id = :storage_object_id, synced_at = :synced_at WHERE id = :file_id",
            named_params! {
                ":file_id": file_id,
                ":storage_object_id": storage_object_id,
                ":synced_at": now_ms(),
            },
        )?;
        Ok(())
    }

    pub fn record_cache_entry(&self, entry: CacheEntryInput<'_>) -> Result<(), SqliteIndexError> {
        self.conn.execute(
            "INSERT INTO cache_entries (
                storage_object_id, workspace_id, file_id, version_id, relative_path,
                size_bytes, sha256_hex, content_type, etag, cached_at, last_accessed_at
             ) VALUES (
                :storage_object_id, :workspace_id, :file_id, :version_id, :relative_path,
                :size_bytes, :sha256_hex, :content_type, :etag, :cached_at, :last_accessed_at
             )
             ON CONFLICT(storage_object_id) DO UPDATE SET
                workspace_id = excluded.workspace_id,
                file_id = excluded.file_id,
                version_id = excluded.version_id,
                relative_path = excluded.relative_path,
                size_bytes = excluded.size_bytes,
                sha256_hex = excluded.sha256_hex,
                content_type = excluded.content_type,
                etag = excluded.etag,
                cached_at = excluded.cached_at,
                last_accessed_at = excluded.last_accessed_at",
            named_params! {
                ":storage_object_id": entry.storage_object_id,
                ":workspace_id": entry.workspace_id,
                ":file_id": entry.file_id,
                ":version_id": entry.version_id,
                ":relative_path": entry.relative_path,
                ":size_bytes": entry.size_bytes,
                ":sha256_hex": entry.sha256_hex,
                ":content_type": entry.content_type,
                ":etag": entry.etag,
                ":cached_at": now_ms(),
                ":last_accessed_at": now_ms(),
            },
        )?;
        self.mark_item_cached(entry.file_id, entry.storage_object_id)?;
        Ok(())
    }

    pub fn cache_entry_for_file(
        &self,
        file_id: &str,
    ) -> Result<Option<CacheEntry>, SqliteIndexError> {
        self.conn
            .query_row(
                "SELECT storage_object_id, workspace_id, file_id, version_id, relative_path,
                        size_bytes, sha256_hex, content_type, etag, cached_at, last_accessed_at,
                        pinned
                 FROM cache_entries
                 WHERE file_id = :file_id
                 ORDER BY cached_at DESC
                 LIMIT 1",
                named_params! { ":file_id": file_id },
                row_to_cache_entry,
            )
            .optional()
            .map_err(SqliteIndexError::from)
    }

    pub fn cache_entry_for_object(
        &self,
        storage_object_id: &str,
    ) -> Result<Option<CacheEntry>, SqliteIndexError> {
        self.conn
            .query_row(
                "SELECT storage_object_id, workspace_id, file_id, version_id, relative_path,
                        size_bytes, sha256_hex, content_type, etag, cached_at, last_accessed_at,
                        pinned
                 FROM cache_entries
                 WHERE storage_object_id = :storage_object_id",
                named_params! { ":storage_object_id": storage_object_id },
                row_to_cache_entry,
            )
            .optional()
            .map_err(SqliteIndexError::from)
    }

    pub fn touch_cache_entry(&self, storage_object_id: &str) -> Result<(), SqliteIndexError> {
        self.conn.execute(
            "UPDATE cache_entries SET last_accessed_at = :last_accessed_at WHERE storage_object_id = :storage_object_id",
            named_params! {
                ":storage_object_id": storage_object_id,
                ":last_accessed_at": now_ms(),
            },
        )?;
        Ok(())
    }

    pub fn set_cache_entry_pinned_for_file(
        &self,
        file_id: &str,
        pinned: bool,
    ) -> Result<Option<CacheEntry>, SqliteIndexError> {
        let Some(entry) = self.cache_entry_for_file(file_id)? else {
            return Ok(None);
        };
        self.conn.execute(
            "UPDATE cache_entries
             SET pinned = :pinned, last_accessed_at = :last_accessed_at
             WHERE storage_object_id = :storage_object_id",
            named_params! {
                ":pinned": if pinned { 1 } else { 0 },
                ":last_accessed_at": now_ms(),
                ":storage_object_id": entry.storage_object_id,
            },
        )?;
        self.conn.execute(
            "UPDATE items
             SET local_state = :local_state, synced_at = :synced_at
             WHERE id = :file_id",
            named_params! {
                ":file_id": file_id,
                ":local_state": if pinned { "pinned" } else { "cached" },
                ":synced_at": now_ms(),
            },
        )?;
        self.cache_entry_for_file(file_id)
    }

    pub fn remove_cache_entry_for_file(
        &self,
        file_id: &str,
    ) -> Result<Option<CacheEntry>, SqliteIndexError> {
        let Some(entry) = self.cache_entry_for_file(file_id)? else {
            return Ok(None);
        };
        self.conn.execute(
            "DELETE FROM cache_entries WHERE storage_object_id = :storage_object_id",
            named_params! { ":storage_object_id": entry.storage_object_id },
        )?;
        self.conn.execute(
            "UPDATE items
             SET local_state = 'online_only', synced_at = :synced_at
             WHERE id = :file_id AND local_state IN ('hydrating', 'cached', 'pinned')",
            named_params! {
                ":file_id": file_id,
                ":synced_at": now_ms(),
            },
        )?;
        Ok(Some(entry))
    }

    pub fn put_cursor(
        &self,
        workspace_id: &str,
        cursor_type: &str,
        scope_id: Option<&str>,
        channel_id: Option<&str>,
        cursor: Option<&str>,
        row_version: Option<u64>,
    ) -> Result<(), SqliteIndexError> {
        self.conn.execute(
            "INSERT INTO cursors (
                workspace_id, scope_id, channel_id, cursor_type, cursor, row_version, updated_at
             ) VALUES (
                :workspace_id, :scope_id, :channel_id, :cursor_type, :cursor, :row_version, :updated_at
             )
             ON CONFLICT(workspace_id, scope_id, channel_id, cursor_type) DO UPDATE SET
                cursor = excluded.cursor,
                row_version = excluded.row_version,
                updated_at = excluded.updated_at",
            named_params! {
                ":workspace_id": workspace_id,
                ":scope_id": scope_id.unwrap_or(""),
                ":channel_id": channel_id.unwrap_or(""),
                ":cursor_type": cursor_type,
                ":cursor": cursor,
                ":row_version": row_version,
                ":updated_at": now_ms(),
            },
        )?;
        Ok(())
    }

    pub fn get_cursor(
        &self,
        workspace_id: &str,
        cursor_type: &str,
        scope_id: Option<&str>,
        channel_id: Option<&str>,
    ) -> Result<Option<String>, SqliteIndexError> {
        self.conn
            .query_row(
                "SELECT cursor FROM cursors
                 WHERE workspace_id = :workspace_id
                   AND scope_id = :scope_id
                   AND channel_id = :channel_id
                   AND cursor_type = :cursor_type",
                named_params! {
                    ":workspace_id": workspace_id,
                    ":scope_id": scope_id.unwrap_or(""),
                    ":channel_id": channel_id.unwrap_or(""),
                    ":cursor_type": cursor_type,
                },
                |row| row.get(0),
            )
            .optional()
            .map_err(SqliteIndexError::from)
    }

    pub fn mark_drive_change(&self, change: &DriveChange) -> Result<(), SqliteIndexError> {
        if change.operation == "deleted" {
            if let Some(id) = change.id.as_deref() {
                self.conn.execute(
                    "UPDATE items SET local_state = 'deleted', deleted_at = :deleted_at, row_version = COALESCE(:row_version, row_version), synced_at = :synced_at WHERE id = :id",
                    named_params! {
                        ":id": id,
                        ":deleted_at": change.timestamp,
                        ":row_version": change.row_version,
                        ":synced_at": now_ms(),
                    },
                )?;
            }
        }
        Ok(())
    }

    pub fn get_item(&self, id: &str) -> Result<Option<LocalItem>, SqliteIndexError> {
        self.conn
            .query_row(
                "SELECT id, item_type, workspace_id, scope_id, channel_id, parent_folder_id,
                        name, current_version_id, storage_object_id, row_version, local_state,
                        updated_at, deleted_at
                 FROM items
                 WHERE id = :id",
                named_params! { ":id": id },
                row_to_item,
            )
            .optional()
            .map_err(SqliteIndexError::from)
    }

    pub fn list_items(&self, workspace_id: &str) -> Result<Vec<LocalItem>, SqliteIndexError> {
        let mut stmt = self.conn.prepare(
            "SELECT id, item_type, workspace_id, scope_id, channel_id, parent_folder_id,
                    name, current_version_id, storage_object_id, row_version, local_state,
                    updated_at, deleted_at
             FROM items
             WHERE workspace_id = :workspace_id
             ORDER BY scope_id, channel_id, item_type, name",
        )?;
        let rows = stmt.query_map(named_params! { ":workspace_id": workspace_id }, row_to_item)?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(SqliteIndexError::from)
    }

    pub fn list_scopes(&self, workspace_id: &str) -> Result<Vec<LocalScope>, SqliteIndexError> {
        let mut stmt = self.conn.prepare(
            "SELECT id, workspace_id, name
             FROM scopes
             WHERE workspace_id = :workspace_id
             ORDER BY name, id",
        )?;
        let rows = stmt.query_map(named_params! { ":workspace_id": workspace_id }, |row| {
            Ok(LocalScope {
                id: row.get(0)?,
                workspace_id: row.get(1)?,
                name: row.get(2)?,
            })
        })?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(SqliteIndexError::from)
    }

    pub fn list_channels(&self, workspace_id: &str) -> Result<Vec<LocalChannel>, SqliteIndexError> {
        let mut stmt = self.conn.prepare(
            "SELECT id, workspace_id, scope_id, name
             FROM channels
             WHERE workspace_id = :workspace_id
             ORDER BY scope_id, name, id",
        )?;
        let rows = stmt.query_map(named_params! { ":workspace_id": workspace_id }, |row| {
            Ok(LocalChannel {
                id: row.get(0)?,
                workspace_id: row.get(1)?,
                scope_id: row.get(2)?,
                name: row.get(3)?,
            })
        })?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(SqliteIndexError::from)
    }

    fn migrate(&self) -> Result<(), SqliteIndexError> {
        self.conn.execute_batch(
            "
            PRAGMA foreign_keys = ON;
            PRAGMA journal_mode = WAL;

            CREATE TABLE IF NOT EXISTS schema_migrations (
                version INTEGER PRIMARY KEY,
                applied_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS accounts (
                signer_npub TEXT NOT NULL,
                actor_id TEXT,
                actor_npub TEXT NOT NULL,
                actor_kind TEXT,
                display_name TEXT,
                workspace_id TEXT NOT NULL,
                membership_role TEXT,
                permissions_json TEXT NOT NULL DEFAULT '[]',
                visible_json TEXT NOT NULL DEFAULT '{}',
                synced_at INTEGER NOT NULL,
                PRIMARY KEY (signer_npub, workspace_id)
            );

            CREATE TABLE IF NOT EXISTS workspaces (
                id TEXT PRIMARY KEY,
                label TEXT NOT NULL,
                slug TEXT,
                description TEXT,
                avatar_url TEXT,
                tower_base_url TEXT,
                row_version INTEGER,
                metadata_json TEXT NOT NULL DEFAULT '{}',
                identity_json TEXT NOT NULL DEFAULT '{}',
                descriptor_json TEXT,
                updated_at TEXT,
                synced_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS scopes (
                id TEXT PRIMARY KEY,
                workspace_id TEXT NOT NULL,
                name TEXT NOT NULL,
                description TEXT,
                kind TEXT,
                owner_actor_id TEXT,
                owner_group_id TEXT,
                default_channel_id TEXT,
                row_version INTEGER NOT NULL,
                created_at TEXT,
                updated_at TEXT,
                source_json TEXT NOT NULL,
                synced_at INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_scopes_workspace ON scopes(workspace_id);

            CREATE TABLE IF NOT EXISTS channels (
                id TEXT PRIMARY KEY,
                workspace_id TEXT NOT NULL,
                scope_id TEXT NOT NULL,
                name TEXT NOT NULL,
                description TEXT,
                kind TEXT,
                participant_npubs_json TEXT,
                metadata_json TEXT NOT NULL DEFAULT '{}',
                row_version INTEGER NOT NULL,
                created_at TEXT,
                updated_at TEXT,
                source_json TEXT NOT NULL,
                synced_at INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_channels_scope ON channels(workspace_id, scope_id);

            CREATE TABLE IF NOT EXISTS items (
                id TEXT PRIMARY KEY,
                item_type TEXT NOT NULL CHECK (item_type IN ('file', 'folder')),
                workspace_id TEXT NOT NULL,
                scope_id TEXT NOT NULL,
                channel_id TEXT NOT NULL,
                parent_folder_id TEXT,
                name TEXT,
                current_version_id TEXT,
                storage_object_id TEXT,
                row_version INTEGER NOT NULL,
                metadata_json TEXT NOT NULL DEFAULT '{}',
                local_state TEXT NOT NULL CHECK (local_state IN (
                    'online_only', 'hydrating', 'cached', 'pinned', 'dirty', 'conflicted', 'deleted'
                )),
                created_at TEXT,
                updated_at TEXT,
                deleted_at TEXT,
                created_by_actor_id TEXT,
                updated_by_actor_id TEXT,
                source_json TEXT NOT NULL,
                synced_at INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_items_parent ON items(workspace_id, channel_id, parent_folder_id);
            CREATE INDEX IF NOT EXISTS idx_items_storage_object ON items(storage_object_id);
            CREATE INDEX IF NOT EXISTS idx_items_state ON items(local_state);

            CREATE TABLE IF NOT EXISTS versions (
                id TEXT PRIMARY KEY,
                workspace_id TEXT NOT NULL,
                file_id TEXT NOT NULL,
                storage_object_id TEXT NOT NULL,
                version_number INTEGER,
                size_bytes INTEGER,
                content_type TEXT,
                sha256_hex TEXT,
                etag TEXT,
                base_version_id TEXT,
                operation TEXT,
                created_at TEXT,
                created_by_actor_id TEXT,
                source_json TEXT NOT NULL DEFAULT '{}',
                synced_at INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_versions_file ON versions(file_id);
            CREATE INDEX IF NOT EXISTS idx_versions_storage_object ON versions(storage_object_id);

            CREATE TABLE IF NOT EXISTS cache_entries (
                storage_object_id TEXT PRIMARY KEY,
                workspace_id TEXT NOT NULL,
                file_id TEXT NOT NULL,
                version_id TEXT,
                relative_path TEXT NOT NULL,
                size_bytes INTEGER NOT NULL,
                sha256_hex TEXT,
                content_type TEXT,
                etag TEXT,
                cached_at INTEGER NOT NULL,
                last_accessed_at INTEGER NOT NULL,
                pinned INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_cache_file ON cache_entries(file_id);
            CREATE INDEX IF NOT EXISTS idx_cache_last_accessed ON cache_entries(last_accessed_at);

            CREATE TABLE IF NOT EXISTS transfers (
                id TEXT PRIMARY KEY,
                workspace_id TEXT NOT NULL,
                file_id TEXT,
                storage_object_id TEXT,
                direction TEXT NOT NULL CHECK (direction IN ('download', 'upload')),
                state TEXT NOT NULL,
                bytes_total INTEGER,
                bytes_done INTEGER NOT NULL DEFAULT 0,
                error TEXT,
                started_at INTEGER,
                updated_at INTEGER NOT NULL,
                completed_at INTEGER
            );
            CREATE INDEX IF NOT EXISTS idx_transfers_state ON transfers(workspace_id, state);

            CREATE TABLE IF NOT EXISTS permissions (
                workspace_id TEXT NOT NULL,
                principal_npub TEXT NOT NULL,
                permission TEXT NOT NULL,
                source_json TEXT NOT NULL,
                synced_at INTEGER NOT NULL,
                PRIMARY KEY (workspace_id, principal_npub, permission)
            );

            CREATE TABLE IF NOT EXISTS cursors (
                workspace_id TEXT NOT NULL,
                scope_id TEXT NOT NULL DEFAULT '',
                channel_id TEXT NOT NULL DEFAULT '',
                cursor_type TEXT NOT NULL,
                cursor TEXT,
                row_version INTEGER,
                updated_at INTEGER NOT NULL,
                PRIMARY KEY (workspace_id, scope_id, channel_id, cursor_type)
            );
            ",
        )?;
        self.conn.execute(
            "INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES (?1, ?2)",
            params![SCHEMA_VERSION, now_ms()],
        )?;
        Ok(())
    }

    fn upsert_drive_version(&self, item: &DriveTreeItem) -> Result<(), SqliteIndexError> {
        let Some(storage_object_id) = item.storage_object_id.as_deref() else {
            return Ok(());
        };
        if item.item_type != DriveItemType::File {
            return Ok(());
        }
        let version_id = item
            .current_version_id
            .as_deref()
            .unwrap_or(storage_object_id);
        self.conn.execute(
            "INSERT INTO versions (
                id, workspace_id, file_id, storage_object_id, operation, created_at, source_json, synced_at
             ) VALUES (
                :id, :workspace_id, :file_id, :storage_object_id, 'visible', :created_at, :source_json, :synced_at
             )
             ON CONFLICT(id) DO UPDATE SET
                workspace_id = excluded.workspace_id,
                file_id = excluded.file_id,
                storage_object_id = excluded.storage_object_id,
                operation = excluded.operation,
                created_at = excluded.created_at,
                source_json = excluded.source_json,
                synced_at = excluded.synced_at",
            named_params! {
                ":id": version_id,
                ":workspace_id": item.workspace_id,
                ":file_id": item.id,
                ":storage_object_id": storage_object_id,
                ":created_at": item.updated_at,
                ":source_json": json_text(item)?,
                ":synced_at": now_ms(),
            },
        )?;
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LocalItem {
    pub id: String,
    pub item_type: String,
    pub workspace_id: String,
    pub scope_id: String,
    pub channel_id: String,
    pub parent_folder_id: Option<String>,
    pub name: Option<String>,
    pub current_version_id: Option<String>,
    pub storage_object_id: Option<String>,
    pub row_version: u64,
    pub local_state: String,
    pub updated_at: Option<String>,
    pub deleted_at: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LocalScope {
    pub id: String,
    pub workspace_id: String,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LocalChannel {
    pub id: String,
    pub workspace_id: String,
    pub scope_id: String,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct CacheEntry {
    pub storage_object_id: String,
    pub workspace_id: String,
    pub file_id: String,
    pub version_id: Option<String>,
    pub relative_path: String,
    pub size_bytes: u64,
    pub sha256_hex: Option<String>,
    pub content_type: Option<String>,
    pub etag: Option<String>,
    pub cached_at: i64,
    pub last_accessed_at: i64,
    pub pinned: bool,
}

#[derive(Debug, Clone, Copy)]
pub struct CacheEntryInput<'a> {
    pub storage_object_id: &'a str,
    pub workspace_id: &'a str,
    pub file_id: &'a str,
    pub version_id: Option<&'a str>,
    pub relative_path: &'a str,
    pub size_bytes: u64,
    pub sha256_hex: Option<&'a str>,
    pub content_type: Option<&'a str>,
    pub etag: Option<&'a str>,
}

fn row_to_item(row: &rusqlite::Row<'_>) -> rusqlite::Result<LocalItem> {
    Ok(LocalItem {
        id: row.get(0)?,
        item_type: row.get(1)?,
        workspace_id: row.get(2)?,
        scope_id: row.get(3)?,
        channel_id: row.get(4)?,
        parent_folder_id: row.get(5)?,
        name: row.get(6)?,
        current_version_id: row.get(7)?,
        storage_object_id: row.get(8)?,
        row_version: row.get(9)?,
        local_state: row.get(10)?,
        updated_at: row.get(11)?,
        deleted_at: row.get(12)?,
    })
}

fn row_to_cache_entry(row: &rusqlite::Row<'_>) -> rusqlite::Result<CacheEntry> {
    Ok(CacheEntry {
        storage_object_id: row.get(0)?,
        workspace_id: row.get(1)?,
        file_id: row.get(2)?,
        version_id: row.get(3)?,
        relative_path: row.get(4)?,
        size_bytes: row.get(5)?,
        sha256_hex: row.get(6)?,
        content_type: row.get(7)?,
        etag: row.get(8)?,
        cached_at: row.get(9)?,
        last_accessed_at: row.get(10)?,
        pinned: row.get::<_, i64>(11)? != 0,
    })
}

fn json_text<T: Serialize + ?Sized>(value: &T) -> Result<String, SqliteIndexError> {
    Ok(serde_json::to_string(value)?)
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or_default()
}

#[allow(dead_code)]
fn json_object() -> Value {
    Value::Object(Default::default())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tower::DriveTreeItem;

    #[test]
    fn schema_version_is_persisted() {
        let index = SqliteIndex::open_in_memory().unwrap();
        assert_eq!(index.schema_version().unwrap(), SCHEMA_VERSION);
    }

    #[test]
    fn drive_items_survive_reopen() {
        let dir = std::env::temp_dir().join(format!("wmapp-index-{}", now_ms()));
        std::fs::create_dir_all(&dir).unwrap();
        let db_path = dir.join("index.sqlite");
        {
            let index = SqliteIndex::open(SqliteIndexConfig {
                path: db_path.clone(),
            })
            .unwrap();
            index
                .upsert_drive_item(&DriveTreeItem {
                    item_type: DriveItemType::File,
                    id: "file-1".to_string(),
                    workspace_id: "workspace-1".to_string(),
                    scope_id: "scope-1".to_string(),
                    channel_id: "channel-1".to_string(),
                    parent_folder_id: Some("folder-1".to_string()),
                    name: Some("report.pdf".to_string()),
                    row_version: 9,
                    current_version_id: Some("version-1".to_string()),
                    storage_object_id: Some("object-1".to_string()),
                    updated_at: Some("2026-07-01T00:00:00.000Z".to_string()),
                    refetch: None,
                })
                .unwrap();
            index
                .put_cursor(
                    "workspace-1",
                    "drive_tree",
                    Some("scope-1"),
                    Some("channel-1"),
                    Some("cursor-1"),
                    Some(9),
                )
                .unwrap();
        }

        let reopened = SqliteIndex::open(SqliteIndexConfig { path: db_path }).unwrap();
        let item = reopened.get_item("file-1").unwrap().unwrap();
        assert_eq!(item.name.as_deref(), Some("report.pdf"));
        assert_eq!(item.storage_object_id.as_deref(), Some("object-1"));
        assert_eq!(item.local_state, "online_only");
        assert_eq!(
            reopened
                .get_cursor(
                    "workspace-1",
                    "drive_tree",
                    Some("scope-1"),
                    Some("channel-1")
                )
                .unwrap()
                .as_deref(),
            Some("cursor-1")
        );
        std::fs::remove_dir_all(dir).unwrap();
    }
}
