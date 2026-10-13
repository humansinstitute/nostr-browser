use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use base64::{engine::general_purpose::STANDARD, Engine as _};
use sha2::{Digest, Sha256};
use thiserror::Error;

use crate::sqlite::{CacheEntry, CacheEntryInput, SqliteIndex, SqliteIndexError};
use crate::tower::FileObjectResponse;

#[derive(Debug, Error)]
pub enum ObjectCacheError {
    #[error("cache I/O error: {0}")]
    Io(#[from] io::Error),
    #[error("object decode error: {0}")]
    Decode(#[from] base64::DecodeError),
    #[error("SQLite index error: {0}")]
    Index(#[from] SqliteIndexError),
    #[error("cache entry is missing for file {0}")]
    MissingEntry(String),
    #[error("cache entry for file {0} is pinned; pass force to evict")]
    PinnedEntry(String),
    #[error("cached object path escapes cache root")]
    InvalidPath,
}

#[derive(Debug, Clone)]
pub struct ObjectCacheConfig {
    pub root: PathBuf,
}

#[derive(Debug, Clone)]
pub struct ObjectCache {
    config: ObjectCacheConfig,
}

impl ObjectCache {
    pub fn open(config: ObjectCacheConfig) -> Result<Self, ObjectCacheError> {
        fs::create_dir_all(config.root.join("objects"))?;
        Ok(Self { config })
    }

    pub fn root(&self) -> &Path {
        &self.config.root
    }

    pub fn put_file_object(
        &self,
        index: &SqliteIndex,
        object: &FileObjectResponse,
    ) -> Result<PathBuf, ObjectCacheError> {
        let bytes = STANDARD.decode(&object.object.base64_data)?;
        let digest = Sha256::digest(&bytes);
        let sha256_hex = hex::encode(digest);
        let object_path = self.object_path(&object.object.object_id)?;
        if let Some(parent) = object_path.parent() {
            fs::create_dir_all(parent)?;
        }
        let temp_path = object_path.with_extension("tmp");
        fs::write(&temp_path, &bytes)?;
        fs::rename(&temp_path, &object_path)?;

        index.upsert_file_object_metadata(&object.file, &object.object)?;
        let relative_path = self.relative_path(&object_path)?;
        let version_id = object
            .file
            .current_version_id
            .as_deref()
            .unwrap_or(object.object.object_id.as_str());
        index.record_cache_entry(CacheEntryInput {
            storage_object_id: &object.object.object_id,
            workspace_id: &object.file.workspace_id,
            file_id: &object.file.id,
            version_id: Some(version_id),
            relative_path: &relative_path,
            size_bytes: bytes.len() as u64,
            sha256_hex: object.object.sha256_hex.as_deref().or(Some(&sha256_hex)),
            content_type: object.object.content_type.as_deref(),
            etag: None,
        })?;
        Ok(object_path)
    }

    pub fn read_file(
        &self,
        index: &SqliteIndex,
        file_id: &str,
    ) -> Result<Vec<u8>, ObjectCacheError> {
        let entry = index
            .cache_entry_for_file(file_id)?
            .ok_or_else(|| ObjectCacheError::MissingEntry(file_id.to_string()))?;
        let path = self.path_from_relative(&entry.relative_path)?;
        let bytes = fs::read(path)?;
        index.touch_cache_entry(&entry.storage_object_id)?;
        Ok(bytes)
    }

    pub fn set_pinned(
        &self,
        index: &SqliteIndex,
        file_id: &str,
        pinned: bool,
    ) -> Result<CacheEntry, ObjectCacheError> {
        index
            .set_cache_entry_pinned_for_file(file_id, pinned)?
            .ok_or_else(|| ObjectCacheError::MissingEntry(file_id.to_string()))
    }

    pub fn evict_file(
        &self,
        index: &SqliteIndex,
        file_id: &str,
        force: bool,
    ) -> Result<CacheEntry, ObjectCacheError> {
        let entry = index
            .cache_entry_for_file(file_id)?
            .ok_or_else(|| ObjectCacheError::MissingEntry(file_id.to_string()))?;
        if entry.pinned && !force {
            return Err(ObjectCacheError::PinnedEntry(file_id.to_string()));
        }

        let path = self.path_from_relative(&entry.relative_path)?;
        if path.exists() {
            fs::remove_file(path)?;
        }
        index.remove_cache_entry_for_file(file_id)?;
        Ok(entry)
    }

    pub fn object_path(&self, storage_object_id: &str) -> Result<PathBuf, ObjectCacheError> {
        let safe_id = storage_object_id.trim();
        if safe_id.is_empty() || safe_id.contains('/') || safe_id.contains('\\') || safe_id == ".."
        {
            return Err(ObjectCacheError::InvalidPath);
        }
        let prefix = safe_id.get(0..2).unwrap_or("xx");
        Ok(self.config.root.join("objects").join(prefix).join(safe_id))
    }

    fn relative_path(&self, path: &Path) -> Result<String, ObjectCacheError> {
        let relative = path
            .strip_prefix(&self.config.root)
            .map_err(|_| ObjectCacheError::InvalidPath)?;
        Ok(relative.to_string_lossy().replace('\\', "/"))
    }

    fn path_from_relative(&self, relative_path: &str) -> Result<PathBuf, ObjectCacheError> {
        let path = self.config.root.join(relative_path);
        let parent = path.parent().unwrap_or(&self.config.root);
        let canonical_parent = parent.canonicalize()?;
        let canonical_root = self.config.root.canonicalize()?;
        if !canonical_parent.starts_with(canonical_root) {
            return Err(ObjectCacheError::InvalidPath);
        }
        Ok(path)
    }
}

#[cfg(test)]
mod tests {
    use base64::{engine::general_purpose::STANDARD, Engine as _};
    use serde_json::json;

    use super::*;
    use crate::sqlite::{SqliteIndex, SqliteIndexConfig};
    use crate::tower::{
        FileMetadata, FileObjectMetadata, FileObjectResponse, FlightDeckPgIdentity,
    };

    #[test]
    fn cached_object_survives_index_and_cache_reopen() {
        let root = std::env::temp_dir().join(format!(
            "wmapp-cache-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_millis()
        ));
        fs::create_dir_all(&root).unwrap();
        let db_path = root.join("index.sqlite");
        let cache_root = root.join("cache");
        {
            let index = SqliteIndex::open(SqliteIndexConfig {
                path: db_path.clone(),
            })
            .unwrap();
            let cache = ObjectCache::open(ObjectCacheConfig {
                root: cache_root.clone(),
            })
            .unwrap();
            cache
                .put_file_object(&index, &file_object_response(b"hello cache"))
                .unwrap();
        }

        let reopened_index = SqliteIndex::open(SqliteIndexConfig { path: db_path }).unwrap();
        let reopened_cache = ObjectCache::open(ObjectCacheConfig { root: cache_root }).unwrap();
        let bytes = reopened_cache.read_file(&reopened_index, "file-1").unwrap();
        assert_eq!(bytes, b"hello cache");
        let item = reopened_index.get_item("file-1").unwrap().unwrap();
        assert_eq!(item.local_state, "cached");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn pinned_cache_entries_require_force_to_evict() {
        let root = std::env::temp_dir().join(format!(
            "wmapp-cache-pin-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_millis()
        ));
        fs::create_dir_all(&root).unwrap();
        let index = SqliteIndex::open(SqliteIndexConfig {
            path: root.join("index.sqlite"),
        })
        .unwrap();
        let cache = ObjectCache::open(ObjectCacheConfig {
            root: root.join("cache"),
        })
        .unwrap();
        cache
            .put_file_object(&index, &file_object_response(b"pin me"))
            .unwrap();

        let pinned = cache.set_pinned(&index, "file-1", true).unwrap();
        assert!(pinned.pinned);
        assert!(matches!(
            cache.evict_file(&index, "file-1", false),
            Err(ObjectCacheError::PinnedEntry(file_id)) if file_id == "file-1"
        ));

        let evicted = cache.evict_file(&index, "file-1", true).unwrap();
        assert_eq!(evicted.file_id, "file-1");
        assert!(matches!(
            cache.read_file(&index, "file-1"),
            Err(ObjectCacheError::MissingEntry(file_id)) if file_id == "file-1"
        ));
        let item = index.get_item("file-1").unwrap().unwrap();
        assert_eq!(item.local_state, "online_only");
        fs::remove_dir_all(root).unwrap();
    }

    fn file_object_response(bytes: &[u8]) -> FileObjectResponse {
        FileObjectResponse {
            identity: FlightDeckPgIdentity {
                tower_service_npub: None,
                workspace_service_npub: None,
                workspace_owner_npub: None,
                workspace_id: Some("workspace-1".to_string()),
                app_npub: Some("npub-app".to_string()),
            },
            file: FileMetadata {
                id: "file-1".to_string(),
                workspace_id: "workspace-1".to_string(),
                scope_id: "scope-1".to_string(),
                channel_id: "channel-1".to_string(),
                folder_id: None,
                storage_object_id: "object-1".to_string(),
                display_name: "note.txt".to_string(),
                description: None,
                metadata: json!({}),
                row_version: 3,
                current_version_id: Some("version-1".to_string()),
                created_by_actor_id: None,
                updated_by_actor_id: None,
                created_at: None,
                updated_at: Some("2026-07-01T00:00:00.000Z".to_string()),
                object: json!({}),
            },
            object: FileObjectMetadata {
                object_id: "object-1".to_string(),
                content_type: Some("text/plain".to_string()),
                file_name: Some("note.txt".to_string()),
                size_bytes: bytes.len() as u64,
                sha256_hex: None,
                encoding: "base64".to_string(),
                base64_data: STANDARD.encode(bytes),
            },
        }
    }
}
