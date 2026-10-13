use std::collections::{BTreeMap, BTreeSet, HashMap};

use serde::Serialize;
use thiserror::Error;

use crate::sqlite::{LocalChannel, LocalItem, LocalScope, SqliteIndex, SqliteIndexError};

#[derive(Debug, Error)]
pub enum DriveProjectionError {
    #[error("SQLite index error: {0}")]
    Index(#[from] SqliteIndexError),
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct DriveProjection {
    pub workspace_id: String,
    pub entries: Vec<ProjectedEntry>,
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct ProjectedEntry {
    pub path: String,
    pub kind: ProjectedEntryKind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub item_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub file_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub local_state: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub storage_object_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub size_bytes: Option<u64>,
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ProjectedEntryKind {
    Directory,
    File,
}

impl DriveProjection {
    pub fn from_index(
        index: &SqliteIndex,
        workspace_id: &str,
    ) -> Result<Self, DriveProjectionError> {
        let scopes = index.list_scopes(workspace_id)?;
        let channels = index.list_channels(workspace_id)?;
        let items = index.list_items(workspace_id)?;
        let mut projection = Self::from_parts(workspace_id, scopes, channels, items);
        for entry in projection
            .entries
            .iter_mut()
            .filter(|entry| entry.kind == ProjectedEntryKind::File)
        {
            let Some(file_id) = entry.file_id.as_deref() else {
                continue;
            };
            if let Some(cache_entry) = index.cache_entry_for_file(file_id)? {
                entry.size_bytes = Some(cache_entry.size_bytes);
            }
        }
        Ok(projection)
    }

    pub fn from_parts(
        workspace_id: &str,
        scopes: Vec<LocalScope>,
        channels: Vec<LocalChannel>,
        items: Vec<LocalItem>,
    ) -> Self {
        let mut entries = Vec::new();
        let mut warnings = Vec::new();
        let mut scopes_by_id: BTreeMap<String, LocalScope> = scopes
            .into_iter()
            .map(|scope| (scope.id.clone(), scope))
            .collect();
        let mut channels_by_scope: BTreeMap<String, Vec<LocalChannel>> = BTreeMap::new();
        for channel in channels {
            channels_by_scope
                .entry(channel.scope_id.clone())
                .or_default()
                .push(channel);
        }
        let mut children_by_parent: BTreeMap<(String, String), Vec<LocalItem>> = BTreeMap::new();
        let mut folder_lookup: HashMap<String, LocalItem> = HashMap::new();
        for item in items {
            if !scopes_by_id.contains_key(&item.scope_id) {
                scopes_by_id.insert(
                    item.scope_id.clone(),
                    LocalScope {
                        id: item.scope_id.clone(),
                        workspace_id: item.workspace_id.clone(),
                        name: item.scope_id.clone(),
                    },
                );
                warnings.push(format!(
                    "scope {} was present in items but missing from the local scope index",
                    item.scope_id
                ));
            }
            if item.item_type == "folder" {
                folder_lookup.insert(item.id.clone(), item.clone());
            }
            let parent_id = item.parent_folder_id.clone().unwrap_or_default();
            children_by_parent
                .entry((item.channel_id.clone(), parent_id))
                .or_default()
                .push(item);
        }

        let mut scope_names = BTreeSet::new();
        for scope in scopes_by_id.values() {
            let scope_name = unique_name(&mut scope_names, &scope.name, &scope.id);
            let scope_path = format!("/{}", scope_name);
            entries.push(directory(&scope_path, Some(scope.id.clone())));

            let mut channel_names = BTreeSet::new();
            if let Some(channels) = channels_by_scope.get(&scope.id) {
                for channel in channels {
                    let channel_name = unique_name(&mut channel_names, &channel.name, &channel.id);
                    let channel_path = format!("{}/{}", scope_path, channel_name);
                    entries.push(directory(&channel_path, Some(channel.id.clone())));
                    add_children(
                        &mut entries,
                        &children_by_parent,
                        &folder_lookup,
                        &channel.id,
                        "",
                        &channel_path,
                    );
                }
            }
        }

        entries.sort_by(|a, b| a.path.cmp(&b.path));
        Self {
            workspace_id: workspace_id.to_string(),
            entries,
            warnings,
        }
    }

    pub fn file_by_path(&self, path: &str) -> Option<&ProjectedEntry> {
        let normalized = normalize_path(path);
        self.entries
            .iter()
            .find(|entry| entry.path == normalized && entry.kind == ProjectedEntryKind::File)
    }
}

fn add_children(
    entries: &mut Vec<ProjectedEntry>,
    children_by_parent: &BTreeMap<(String, String), Vec<LocalItem>>,
    folder_lookup: &HashMap<String, LocalItem>,
    channel_id: &str,
    parent_id: &str,
    parent_path: &str,
) {
    let Some(children) = children_by_parent.get(&(channel_id.to_string(), parent_id.to_string()))
    else {
        return;
    };
    let mut child_names = BTreeSet::new();
    let mut sorted_children = children.clone();
    sorted_children.sort_by(|a, b| {
        a.item_type
            .cmp(&b.item_type)
            .then(a.name.cmp(&b.name))
            .then(a.id.cmp(&b.id))
    });

    for item in sorted_children {
        let fallback = item.id.clone();
        let raw_name = item.name.as_deref().unwrap_or(&fallback);
        let name = unique_name(&mut child_names, raw_name, &item.id);
        let path = format!("{}/{}", parent_path, name);
        if item.item_type == "folder" {
            entries.push(directory(&path, Some(item.id.clone())));
            if folder_lookup.contains_key(&item.id) {
                add_children(
                    entries,
                    children_by_parent,
                    folder_lookup,
                    channel_id,
                    &item.id,
                    &path,
                );
            }
        } else {
            entries.push(ProjectedEntry {
                path,
                kind: ProjectedEntryKind::File,
                item_id: Some(item.id.clone()),
                file_id: Some(item.id),
                local_state: Some(item.local_state),
                storage_object_id: item.storage_object_id,
                size_bytes: None,
            });
        }
    }
}

fn directory(path: &str, item_id: Option<String>) -> ProjectedEntry {
    ProjectedEntry {
        path: path.to_string(),
        kind: ProjectedEntryKind::Directory,
        item_id,
        file_id: None,
        local_state: None,
        storage_object_id: None,
        size_bytes: None,
    }
}

fn unique_name(seen: &mut BTreeSet<String>, raw_name: &str, id: &str) -> String {
    let base = sanitize_name(raw_name);
    if seen.insert(base.clone()) {
        return base;
    }
    let suffix = id.chars().take(8).collect::<String>();
    let with_suffix = format!("{base} [{suffix}]");
    if seen.insert(with_suffix.clone()) {
        return with_suffix;
    }
    let mut counter = 2;
    loop {
        let candidate = format!("{base} [{suffix}-{counter}]");
        if seen.insert(candidate.clone()) {
            return candidate;
        }
        counter += 1;
    }
}

fn sanitize_name(name: &str) -> String {
    let sanitized = name
        .chars()
        .map(|ch| match ch {
            '/' | '\\' | ':' | '\0' => '_',
            ch if ch.is_control() => '_',
            ch => ch,
        })
        .collect::<String>()
        .trim()
        .trim_matches('.')
        .to_string();
    if sanitized.is_empty() {
        "Untitled".to_string()
    } else {
        sanitized
    }
}

fn normalize_path(path: &str) -> String {
    if path.starts_with('/') {
        path.to_string()
    } else {
        format!("/{path}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn projection_builds_scope_channel_folder_file_tree() {
        let projection = DriveProjection::from_parts(
            "workspace-1",
            vec![LocalScope {
                id: "scope-1".to_string(),
                workspace_id: "workspace-1".to_string(),
                name: "Client/Work".to_string(),
            }],
            vec![LocalChannel {
                id: "channel-1".to_string(),
                workspace_id: "workspace-1".to_string(),
                scope_id: "scope-1".to_string(),
                name: "General".to_string(),
            }],
            vec![
                item("folder-1", "folder", Some("Reports"), None),
                item("file-1", "file", Some("summary.txt"), Some("folder-1")),
            ],
        );

        let paths = projection
            .entries
            .iter()
            .map(|entry| entry.path.as_str())
            .collect::<Vec<_>>();
        assert_eq!(
            paths,
            vec![
                "/Client_Work",
                "/Client_Work/General",
                "/Client_Work/General/Reports",
                "/Client_Work/General/Reports/summary.txt",
            ]
        );
        assert_eq!(
            projection
                .file_by_path("Client_Work/General/Reports/summary.txt")
                .and_then(|entry| entry.file_id.as_deref()),
            Some("file-1")
        );
    }

    #[test]
    fn projection_disambiguates_duplicate_names() {
        let projection = DriveProjection::from_parts(
            "workspace-1",
            vec![LocalScope {
                id: "scope-1".to_string(),
                workspace_id: "workspace-1".to_string(),
                name: "Scope".to_string(),
            }],
            vec![LocalChannel {
                id: "channel-1".to_string(),
                workspace_id: "workspace-1".to_string(),
                scope_id: "scope-1".to_string(),
                name: "Files".to_string(),
            }],
            vec![
                item("file-aaaa1111", "file", Some("note.txt"), None),
                item("file-bbbb2222", "file", Some("note.txt"), None),
            ],
        );

        let file_paths = projection
            .entries
            .iter()
            .filter(|entry| entry.kind == ProjectedEntryKind::File)
            .map(|entry| entry.path.as_str())
            .collect::<Vec<_>>();
        assert_eq!(
            file_paths,
            vec!["/Scope/Files/note.txt", "/Scope/Files/note.txt [file-bbb]"]
        );
    }

    fn item(
        id: &str,
        item_type: &str,
        name: Option<&str>,
        parent_folder_id: Option<&str>,
    ) -> LocalItem {
        LocalItem {
            id: id.to_string(),
            item_type: item_type.to_string(),
            workspace_id: "workspace-1".to_string(),
            scope_id: "scope-1".to_string(),
            channel_id: "channel-1".to_string(),
            parent_folder_id: parent_folder_id.map(ToString::to_string),
            name: name.map(ToString::to_string),
            current_version_id: None,
            storage_object_id: Some(format!("object-{id}")),
            row_version: 1,
            local_state: "online_only".to_string(),
            updated_at: None,
            deleted_at: None,
        }
    }
}
