use crate::sqlite::{SqliteIndex, SqliteIndexError};
use crate::tower::{
    Channel, DriveDeltaResponse, DriveTreeResponse, Scope, WorkspaceDescriptor,
    WorkspaceMeResponse, WorkspaceSummary,
};
use serde::Serialize;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LocalItemState {
    OnlineOnly,
    Hydrating,
    Cached,
    Pinned,
    Dirty,
    Conflicted,
    Deleted,
}

#[derive(Debug, Default)]
pub struct SyncEngine;

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct SyncSummary {
    pub workspaces: usize,
    pub scopes: usize,
    pub channels: usize,
    pub items: usize,
    pub changes: usize,
    pub permissions: usize,
}

#[derive(Debug, Default)]
pub struct VisibleMetadata<'a> {
    pub workspace_summaries: &'a [WorkspaceSummary],
    pub workspace_descriptor: Option<&'a WorkspaceDescriptor>,
    pub workspace_me: Option<&'a WorkspaceMeResponse>,
    pub scopes: &'a [Scope],
    pub channels: &'a [Channel],
    pub drive_tree: Option<&'a DriveTreeResponse>,
    pub drive_delta: Option<&'a DriveDeltaResponse>,
}

impl SyncEngine {
    pub fn new() -> Self {
        Self
    }

    pub fn persist_visible_metadata(
        &self,
        index: &SqliteIndex,
        metadata: VisibleMetadata<'_>,
    ) -> Result<SyncSummary, SqliteIndexError> {
        let mut summary = SyncSummary::default();

        for workspace in metadata.workspace_summaries {
            index.upsert_workspace_summary(workspace)?;
            summary.workspaces += 1;
        }

        if let Some(descriptor) = metadata.workspace_descriptor {
            index.upsert_workspace_descriptor(descriptor)?;
            summary.workspaces += 1;
        }

        if let (Some(descriptor), Some(me)) = (metadata.workspace_descriptor, metadata.workspace_me)
        {
            let workspace_id = descriptor.identity.workspace_id.as_deref().unwrap_or("");
            summary.permissions += index.upsert_workspace_permissions(workspace_id, me)?;
        }

        for scope in metadata.scopes {
            index.upsert_scope(scope)?;
            summary.scopes += 1;
        }

        for channel in metadata.channels {
            index.upsert_channel(channel)?;
            summary.channels += 1;
        }

        if let Some(tree) = metadata.drive_tree {
            for item in &tree.items {
                index.upsert_drive_item(item)?;
                summary.items += 1;
            }
            if let Some(workspace_id) = tree.identity.workspace_id.as_deref() {
                index.put_cursor(
                    workspace_id,
                    "drive_tree",
                    None,
                    None,
                    tree.next_cursor.as_deref(),
                    tree.items.iter().map(|item| item.row_version).max(),
                )?;
            }
        }

        if let Some(delta) = metadata.drive_delta {
            for change in &delta.changes {
                index.mark_drive_change(change)?;
                summary.changes += 1;
            }
            if let Some(workspace_id) = delta.identity.workspace_id.as_deref() {
                index.put_cursor(
                    workspace_id,
                    "drive_delta",
                    None,
                    None,
                    delta.next_cursor.as_deref(),
                    delta
                        .changes
                        .iter()
                        .map(|change| change.event_row_version)
                        .max(),
                )?;
            }
        }

        Ok(summary)
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::sqlite::SqliteIndex;
    use crate::tower::{
        DriveItemType, DriveTreeItem, FlightDeckPgIdentity, Scope, WorkspaceDescriptor,
    };

    #[test]
    fn sync_pass_persists_visible_drive_metadata() {
        let index = SqliteIndex::open_in_memory().unwrap();
        let engine = SyncEngine::new();
        let descriptor = WorkspaceDescriptor {
            r#type: "flightdeck_pg_workspace".to_string(),
            version: 1,
            identity: identity(),
            tower_base_url: "http://127.0.0.1:3100".to_string(),
            label: "Workspace".to_string(),
            slug: Some("workspace".to_string()),
            description: None,
            avatar_url: None,
            metadata: json!({}),
            capabilities: vec![],
            links: json!({}),
            created_at: Some("2026-07-01T00:00:00.000Z".to_string()),
        };
        let scope = Scope {
            id: "scope-1".to_string(),
            workspace_id: "workspace-1".to_string(),
            name: "Scope".to_string(),
            description: None,
            kind: Some("project".to_string()),
            owner_actor_id: None,
            owner_group_id: None,
            default_channel_id: Some("channel-1".to_string()),
            row_version: 2,
            created_at: None,
            updated_at: None,
        };
        let tree = DriveTreeResponse {
            identity: identity(),
            items: vec![DriveTreeItem {
                item_type: DriveItemType::File,
                id: "file-1".to_string(),
                workspace_id: "workspace-1".to_string(),
                scope_id: "scope-1".to_string(),
                channel_id: "channel-1".to_string(),
                parent_folder_id: None,
                name: Some("report.pdf".to_string()),
                row_version: 4,
                current_version_id: Some("version-1".to_string()),
                storage_object_id: Some("object-1".to_string()),
                updated_at: Some("2026-07-01T00:00:00.000Z".to_string()),
                refetch: None,
            }],
            next_cursor: Some("cursor-2".to_string()),
            cursor_semantics: json!({}),
        };

        let summary = engine
            .persist_visible_metadata(
                &index,
                VisibleMetadata {
                    workspace_descriptor: Some(&descriptor),
                    scopes: std::slice::from_ref(&scope),
                    drive_tree: Some(&tree),
                    ..VisibleMetadata::default()
                },
            )
            .unwrap();

        assert_eq!(summary.workspaces, 1);
        assert_eq!(summary.scopes, 1);
        assert_eq!(summary.items, 1);
        let item = index.get_item("file-1").unwrap().unwrap();
        assert_eq!(item.name.as_deref(), Some("report.pdf"));
        assert_eq!(item.current_version_id.as_deref(), Some("version-1"));
        assert_eq!(
            index
                .get_cursor("workspace-1", "drive_tree", None, None)
                .unwrap()
                .as_deref(),
            Some("cursor-2")
        );
    }

    fn identity() -> FlightDeckPgIdentity {
        FlightDeckPgIdentity {
            tower_service_npub: None,
            workspace_service_npub: None,
            workspace_owner_npub: None,
            workspace_id: Some("workspace-1".to_string()),
            app_npub: Some("npub-app".to_string()),
        }
    }
}
