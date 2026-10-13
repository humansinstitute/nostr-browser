use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use reqwest::blocking::{Client as HttpClient, Response};
use reqwest::header::{
    HeaderMap, HeaderValue, ACCEPT, AUTHORIZATION, CONTENT_RANGE, CONTENT_TYPE, ETAG, RANGE,
};
use reqwest::Method;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use thiserror::Error;
use url::Url;

use crate::{auth::Nip98Error, DeviceKey, Nip98Request, Nip98Signer};

const APP_NPUB_HEADER: &str = "x-flightdeck-pg-app-npub";

#[derive(Debug, Error)]
pub enum TowerClientError {
    #[error("invalid Tower client config: {0}")]
    InvalidConfig(String),
    #[error("NIP-98 signing failed: {0}")]
    Auth(#[from] Nip98Error),
    #[error("HTTP request failed: {0}")]
    Http(#[from] reqwest::Error),
    #[error("Tower returned HTTP {status}: {body}")]
    HttpStatus { status: u16, body: String },
    #[error("Tower response could not be decoded: {0}")]
    Decode(String),
    #[error("invalid header value: {0}")]
    Header(String),
    #[error("Tower route is not supported by the current contract: {0}")]
    UnsupportedByTowerContract(&'static str),
}

#[derive(Debug, Clone)]
pub struct TowerClientConfig {
    pub tower_url: Url,
    pub app_npub: String,
}

impl TowerClientConfig {
    pub fn new(
        tower_url: impl AsRef<str>,
        app_npub: impl Into<String>,
    ) -> Result<Self, TowerClientError> {
        let tower_url = Url::parse(tower_url.as_ref().trim())
            .map_err(|error| TowerClientError::InvalidConfig(error.to_string()))?;
        let app_npub = app_npub.into().trim().to_string();
        if app_npub.is_empty() {
            return Err(TowerClientError::InvalidConfig(
                "Flight Deck app npub is required".to_string(),
            ));
        }
        Ok(Self {
            tower_url,
            app_npub,
        })
    }
}

pub struct TowerClient {
    config: TowerClientConfig,
    signer: Nip98Signer,
    http: HttpClient,
}

impl TowerClient {
    pub fn new(config: TowerClientConfig, device_key: DeviceKey) -> Self {
        Self {
            config,
            signer: Nip98Signer::new(device_key),
            http: HttpClient::new(),
        }
    }

    pub fn config(&self) -> &TowerClientConfig {
        &self.config
    }

    pub fn signer_public_key_hex(&self) -> String {
        self.signer.public_key_hex()
    }

    pub fn service(&self) -> Result<ServiceResponse, TowerClientError> {
        self.get_json(path(&["api", "v4", "flightdeck-pg", "service"])?, &[], None)
    }

    pub fn list_workspaces(&self) -> Result<WorkspacesResponse, TowerClientError> {
        self.get_json(
            path(&["api", "v4", "flightdeck-pg", "workspaces"])?,
            &[],
            None,
        )
    }

    pub fn workspace_descriptor(
        &self,
        workspace_id: &str,
    ) -> Result<WorkspaceDescriptor, TowerClientError> {
        self.get_json(
            path(&[
                "api",
                "v4",
                "flightdeck-pg",
                "workspaces",
                workspace_id,
                "descriptor",
            ])?,
            &[],
            None,
        )
    }

    pub fn workspace_me(
        &self,
        workspace_id: &str,
    ) -> Result<WorkspaceMeResponse, TowerClientError> {
        self.get_json(
            path(&[
                "api",
                "v4",
                "flightdeck-pg",
                "workspaces",
                workspace_id,
                "me",
            ])?,
            &[],
            None,
        )
    }

    pub fn list_scopes(&self, workspace_id: &str) -> Result<ScopesResponse, TowerClientError> {
        self.get_json(
            path(&[
                "api",
                "v4",
                "flightdeck-pg",
                "workspaces",
                workspace_id,
                "scopes",
            ])?,
            &[],
            None,
        )
    }

    pub fn list_channels(
        &self,
        workspace_id: &str,
        scope_id: &str,
        limit: Option<u16>,
    ) -> Result<ChannelsResponse, TowerClientError> {
        let limit_value = limit.map(|value| value.to_string());
        let mut query = Vec::new();
        if let Some(value) = limit_value.as_deref() {
            query.push(("limit", value));
        }
        self.get_json(
            path(&[
                "api",
                "v4",
                "flightdeck-pg",
                "workspaces",
                workspace_id,
                "scopes",
                scope_id,
                "channels",
            ])?,
            &query,
            None,
        )
    }

    pub fn get_channel(
        &self,
        workspace_id: &str,
        channel_id: &str,
    ) -> Result<ChannelResponse, TowerClientError> {
        self.get_json(
            path(&[
                "api",
                "v4",
                "flightdeck-pg",
                "workspaces",
                workspace_id,
                "channels",
                channel_id,
            ])?,
            &[],
            None,
        )
    }

    pub fn register_device(
        &self,
        input: &RegisterDeviceRequest,
    ) -> Result<DeviceResponse, TowerClientError> {
        self.post_json(path(&["api", "v4", "user", "devices"])?, &[], input)
    }

    pub fn list_devices(&self) -> Result<DevicesResponse, TowerClientError> {
        self.get_json(path(&["api", "v4", "user", "devices"])?, &[], None)
    }

    pub fn touch_device_seen(
        &self,
        device_npub: &str,
        input: &DeviceSeenRequest,
    ) -> Result<DeviceResponse, TowerClientError> {
        self.post_json(
            path(&["api", "v4", "user", "devices", device_npub, "seen"])?,
            &[],
            input,
        )
    }

    pub fn revoke_device(&self, device_npub: &str) -> Result<DeviceResponse, TowerClientError> {
        self.post_json(
            path(&["api", "v4", "user", "devices", device_npub, "revoke"])?,
            &[],
            &serde_json::json!({}),
        )
    }

    pub fn drive_tree(
        &self,
        workspace_id: &str,
        options: DriveTreeOptions<'_>,
    ) -> Result<DriveTreeResponse, TowerClientError> {
        let limit = options.limit.map(|value| value.to_string());
        let mut query = Vec::new();
        if let Some(scope_id) = options.scope_id {
            query.push(("scope_id", scope_id));
        }
        if let Some(channel_id) = options.channel_id {
            query.push(("channel_id", channel_id));
        }
        if let Some(parent_folder_id) = options.parent_folder_id {
            query.push(("parent_folder_id", parent_folder_id));
        }
        if let Some(cursor) = options.cursor {
            query.push(("cursor", cursor));
        }
        if let Some(value) = limit.as_deref() {
            query.push(("limit", value));
        }
        self.get_json(
            path(&[
                "api",
                "v4",
                "flightdeck-pg",
                "workspaces",
                workspace_id,
                "drive",
                "tree",
            ])?,
            &query,
            None,
        )
    }

    pub fn drive_delta(
        &self,
        workspace_id: &str,
        options: DriveDeltaOptions<'_>,
    ) -> Result<DriveDeltaResponse, TowerClientError> {
        let cursor = match options.cursor {
            Some(cursor) => cursor,
            None => zero_event_cursor(),
        };
        let limit = options.limit.map(|value| value.to_string());
        let mut query = vec![("cursor", cursor)];
        if let Some(scope_id) = options.scope_id {
            query.push(("scope_id", scope_id));
        }
        if let Some(channel_id) = options.channel_id {
            query.push(("channel_id", channel_id));
        }
        if let Some(value) = limit.as_deref() {
            query.push(("limit", value));
        }
        self.get_json(
            path(&[
                "api",
                "v4",
                "flightdeck-pg",
                "workspaces",
                workspace_id,
                "drive",
                "delta",
            ])?,
            &query,
            None,
        )
    }

    pub fn get_file(
        &self,
        workspace_id: &str,
        file_id: &str,
    ) -> Result<FileResponse, TowerClientError> {
        self.get_json(
            path(&[
                "api",
                "v4",
                "flightdeck-pg",
                "workspaces",
                workspace_id,
                "files",
                file_id,
            ])?,
            &[],
            None,
        )
    }

    pub fn get_file_object(
        &self,
        workspace_id: &str,
        file_id: &str,
    ) -> Result<FileObjectResponse, TowerClientError> {
        self.get_json(
            path(&[
                "api",
                "v4",
                "flightdeck-pg",
                "workspaces",
                workspace_id,
                "files",
                file_id,
                "object",
            ])?,
            &[],
            None,
        )
    }

    pub fn get_file_object_range(
        &self,
        workspace_id: &str,
        file_id: &str,
        range: ByteRange,
    ) -> Result<FileObjectBytes, TowerClientError> {
        let url = self.url(
            path(&[
                "api",
                "v4",
                "flightdeck-pg",
                "workspaces",
                workspace_id,
                "files",
                file_id,
                "object",
            ])?,
            &[],
        );
        let response = self.signed_get(
            url,
            Some(
                HeaderValue::from_str(&range.header_value())
                    .map_err(|error| TowerClientError::Header(error.to_string()))?,
            ),
        )?;
        let status = response.status();
        let headers = response.headers().clone();
        let bytes = read_success_bytes(response)?;
        Ok(FileObjectBytes {
            status: status.as_u16(),
            bytes,
            content_type: header_to_string(&headers, CONTENT_TYPE.as_str()),
            content_range: header_to_string(&headers, CONTENT_RANGE.as_str()),
            accept_ranges: header_to_string(&headers, "accept-ranges"),
            etag: header_to_string(&headers, ETAG.as_str()),
        })
    }

    pub fn replace_file_content(&self) -> Result<(), TowerClientError> {
        Err(TowerClientError::UnsupportedByTowerContract(
            "file content replacement requires WMAPP TOWER-GAP-03",
        ))
    }

    pub fn delete_file(&self) -> Result<(), TowerClientError> {
        Err(TowerClientError::UnsupportedByTowerContract(
            "file tombstones require WMAPP TOWER-GAP-04",
        ))
    }

    fn get_json<T: DeserializeOwned>(
        &self,
        path: String,
        query: &[(&str, &str)],
        range: Option<HeaderValue>,
    ) -> Result<T, TowerClientError> {
        let response = self.signed_get(self.url(path, query), range)?;
        let text = read_success_text(response)?;
        serde_json::from_str(&text).map_err(|error| TowerClientError::Decode(error.to_string()))
    }

    fn signed_get(
        &self,
        url: Url,
        range: Option<HeaderValue>,
    ) -> Result<Response, TowerClientError> {
        let auth = self
            .signer
            .sign(Nip98Request::new("GET", url.as_str())?)?
            .authorization_header()?;
        let mut headers = HeaderMap::new();
        headers.insert(ACCEPT, HeaderValue::from_static("*/*"));
        headers.insert(
            AUTHORIZATION,
            HeaderValue::from_str(&auth)
                .map_err(|error| TowerClientError::Header(error.to_string()))?,
        );
        headers.insert(
            APP_NPUB_HEADER,
            HeaderValue::from_str(&self.config.app_npub)
                .map_err(|error| TowerClientError::Header(error.to_string()))?,
        );
        if let Some(range) = range {
            headers.insert(RANGE, range);
        }
        Ok(self
            .http
            .request(Method::GET, url)
            .headers(headers)
            .send()?)
    }

    fn post_json<T: Serialize, R: DeserializeOwned>(
        &self,
        path: String,
        query: &[(&str, &str)],
        body: &T,
    ) -> Result<R, TowerClientError> {
        let bytes = serde_json::to_vec(body)
            .map_err(|error| TowerClientError::Decode(error.to_string()))?;
        let response = self.signed_json_request(Method::POST, self.url(path, query), bytes)?;
        let text = read_success_text(response)?;
        serde_json::from_str(&text).map_err(|error| TowerClientError::Decode(error.to_string()))
    }

    fn signed_json_request(
        &self,
        method: Method,
        url: Url,
        body: Vec<u8>,
    ) -> Result<Response, TowerClientError> {
        let auth = self
            .signer
            .sign(Nip98Request::new(method.as_str(), url.as_str())?.with_body(body.clone()))?
            .authorization_header()?;
        let mut headers = HeaderMap::new();
        headers.insert(ACCEPT, HeaderValue::from_static("application/json"));
        headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
        headers.insert(
            AUTHORIZATION,
            HeaderValue::from_str(&auth)
                .map_err(|error| TowerClientError::Header(error.to_string()))?,
        );
        headers.insert(
            APP_NPUB_HEADER,
            HeaderValue::from_str(&self.config.app_npub)
                .map_err(|error| TowerClientError::Header(error.to_string()))?,
        );
        Ok(self
            .http
            .request(method, url)
            .headers(headers)
            .body(body)
            .send()?)
    }

    fn url(&self, path: String, query: &[(&str, &str)]) -> Url {
        let mut url = self.config.tower_url.clone();
        url.set_path(&path);
        url.set_query(None);
        for (name, value) in query {
            url.query_pairs_mut().append_pair(name, value);
        }
        url
    }
}

#[derive(Debug, Clone, Copy, Default)]
pub struct DriveTreeOptions<'a> {
    pub scope_id: Option<&'a str>,
    pub channel_id: Option<&'a str>,
    pub parent_folder_id: Option<&'a str>,
    pub cursor: Option<&'a str>,
    pub limit: Option<u16>,
}

#[derive(Debug, Clone, Copy, Default)]
pub struct DriveDeltaOptions<'a> {
    pub scope_id: Option<&'a str>,
    pub channel_id: Option<&'a str>,
    pub cursor: Option<&'a str>,
    pub limit: Option<u16>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ByteRange {
    FromTo { start: u64, end: u64 },
    From { start: u64 },
    Suffix { length: u64 },
}

impl ByteRange {
    pub fn bytes(start: u64, end: u64) -> Self {
        Self::FromTo { start, end }
    }

    pub fn header_value(&self) -> String {
        match self {
            Self::FromTo { start, end } => format!("bytes={start}-{end}"),
            Self::From { start } => format!("bytes={start}-"),
            Self::Suffix { length } => format!("bytes=-{length}"),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct FlightDeckPgIdentity {
    pub tower_service_npub: Option<String>,
    pub workspace_service_npub: Option<String>,
    pub workspace_owner_npub: Option<String>,
    pub workspace_id: Option<String>,
    pub app_npub: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServiceResponse {
    pub identity: FlightDeckPgIdentity,
    pub service: TowerService,
    #[serde(default)]
    pub capabilities: Vec<String>,
    #[serde(default)]
    pub links: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TowerService {
    pub name: Option<String>,
    pub description: Option<String>,
    pub base_url: Option<String>,
    pub service_npub: Option<String>,
    pub version: Option<String>,
    pub schema_version: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkspacesResponse {
    pub identity: FlightDeckPgIdentity,
    #[serde(default)]
    pub workspaces: Vec<WorkspaceSummary>,
    pub next_cursor: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkspaceSummary {
    pub identity: FlightDeckPgIdentity,
    pub label: String,
    pub slug: Option<String>,
    pub description: Option<String>,
    pub avatar_url: Option<String>,
    #[serde(default)]
    pub metadata: Value,
    pub tower_base_url: Option<String>,
    #[serde(default)]
    pub capabilities: Vec<String>,
    #[serde(default)]
    pub links: Value,
    pub membership: Option<WorkspaceMembership>,
    pub created_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkspaceDescriptor {
    pub r#type: String,
    pub version: u64,
    pub identity: FlightDeckPgIdentity,
    pub tower_base_url: String,
    pub label: String,
    pub slug: Option<String>,
    pub description: Option<String>,
    pub avatar_url: Option<String>,
    #[serde(default)]
    pub metadata: Value,
    #[serde(default)]
    pub capabilities: Vec<String>,
    #[serde(default)]
    pub links: Value,
    pub created_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkspaceMeResponse {
    pub identity: FlightDeckPgIdentity,
    pub actor: WorkspaceActor,
    pub membership: WorkspaceMembership,
    #[serde(default)]
    pub permissions: Vec<String>,
    #[serde(default)]
    pub visible: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkspaceActor {
    pub actor_id: String,
    pub npub: String,
    pub kind: String,
    pub display_name: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkspaceMembership {
    pub role: String,
    pub joined_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScopesResponse {
    pub identity: FlightDeckPgIdentity,
    #[serde(default)]
    pub scopes: Vec<Scope>,
    pub next_cursor: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Scope {
    pub id: String,
    pub workspace_id: String,
    pub name: String,
    pub description: Option<String>,
    pub kind: Option<String>,
    pub owner_actor_id: Option<String>,
    pub owner_group_id: Option<String>,
    pub default_channel_id: Option<String>,
    pub row_version: u64,
    pub created_at: Option<String>,
    pub updated_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChannelsResponse {
    pub identity: FlightDeckPgIdentity,
    #[serde(default)]
    pub channels: Vec<Channel>,
    pub next_cursor: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChannelResponse {
    pub identity: FlightDeckPgIdentity,
    pub channel: Channel,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Channel {
    pub id: String,
    pub workspace_id: String,
    pub scope_id: String,
    pub name: String,
    pub description: Option<String>,
    #[serde(default)]
    pub metadata: Value,
    pub kind: Option<String>,
    pub participant_npubs: Option<Vec<String>>,
    pub row_version: u64,
    pub created_at: Option<String>,
    pub updated_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RegisterDeviceRequest {
    pub workspace_service_npub: String,
    pub device_npub: String,
    pub label: Option<String>,
    pub platform: Option<String>,
    #[serde(default)]
    pub policy: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceSeenRequest {
    pub workspace_service_npub: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceResponse {
    pub device: DeviceRecord,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DevicesResponse {
    #[serde(default)]
    pub devices: Vec<DeviceRecord>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceRecord {
    pub id: String,
    pub device_npub: String,
    pub user_npub: String,
    pub workspace_owner_npub: String,
    pub workspace_service_npub: String,
    pub label: Option<String>,
    pub platform: Option<String>,
    #[serde(default)]
    pub policy: Value,
    pub status: String,
    pub active: bool,
    pub last_seen_at: Option<String>,
    pub revoked_at: Option<String>,
    pub registered_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DriveTreeResponse {
    pub identity: FlightDeckPgIdentity,
    #[serde(default)]
    pub items: Vec<DriveTreeItem>,
    pub next_cursor: Option<String>,
    #[serde(default)]
    pub cursor_semantics: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DriveTreeItem {
    #[serde(rename = "type")]
    pub item_type: DriveItemType,
    pub id: String,
    pub workspace_id: String,
    pub scope_id: String,
    pub channel_id: String,
    pub parent_folder_id: Option<String>,
    pub name: Option<String>,
    pub row_version: u64,
    pub current_version_id: Option<String>,
    pub storage_object_id: Option<String>,
    pub updated_at: Option<String>,
    pub refetch: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DriveItemType {
    File,
    Folder,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DriveDeltaResponse {
    pub identity: FlightDeckPgIdentity,
    #[serde(default)]
    pub changes: Vec<DriveChange>,
    pub next_cursor: Option<String>,
    #[serde(default)]
    pub has_more: bool,
    #[serde(default)]
    pub cursor_semantics: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DriveChange {
    #[serde(rename = "type")]
    pub item_type: DriveItemType,
    pub id: Option<String>,
    pub operation: String,
    pub row_version: Option<u64>,
    pub event_row_version: u64,
    pub cursor: Option<String>,
    pub scope_id: Option<String>,
    pub channel_id: Option<String>,
    pub timestamp: Option<String>,
    pub refetch: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileResponse {
    pub identity: FlightDeckPgIdentity,
    pub file: FileMetadata,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileObjectResponse {
    pub identity: FlightDeckPgIdentity,
    pub file: FileMetadata,
    pub object: FileObjectMetadata,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileMetadata {
    pub id: String,
    pub workspace_id: String,
    pub scope_id: String,
    pub channel_id: String,
    pub folder_id: Option<String>,
    pub storage_object_id: String,
    pub display_name: String,
    pub description: Option<String>,
    #[serde(default)]
    pub metadata: Value,
    pub row_version: u64,
    pub current_version_id: Option<String>,
    pub created_by_actor_id: Option<String>,
    pub updated_by_actor_id: Option<String>,
    pub created_at: Option<String>,
    pub updated_at: Option<String>,
    #[serde(default)]
    pub object: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileObjectMetadata {
    pub object_id: String,
    pub content_type: Option<String>,
    pub file_name: Option<String>,
    pub size_bytes: u64,
    pub sha256_hex: Option<String>,
    pub encoding: String,
    pub base64_data: String,
}

#[derive(Debug, Clone)]
pub struct FileObjectBytes {
    pub status: u16,
    pub bytes: Vec<u8>,
    pub content_type: Option<String>,
    pub content_range: Option<String>,
    pub accept_ranges: Option<String>,
    pub etag: Option<String>,
}

pub fn zero_event_cursor() -> &'static str {
    "eyJ2ZXJzaW9uIjoxLCJyb3dWZXJzaW9uIjowfQ"
}

fn path(segments: &[&str]) -> Result<String, TowerClientError> {
    let base = Url::parse("http://tower.local/")
        .map_err(|error| TowerClientError::InvalidConfig(error.to_string()))?;
    let mut url = base;
    {
        let mut path_segments = url.path_segments_mut().map_err(|_| {
            TowerClientError::InvalidConfig("base URL cannot be a base".to_string())
        })?;
        path_segments.clear();
        for segment in segments {
            path_segments.push(segment);
        }
    }
    Ok(url.path().to_string())
}

fn read_success_text(response: Response) -> Result<String, TowerClientError> {
    let status = response.status();
    let text = response.text()?;
    if !status.is_success() {
        return Err(TowerClientError::HttpStatus {
            status: status.as_u16(),
            body: text,
        });
    }
    Ok(text)
}

fn read_success_bytes(response: Response) -> Result<Vec<u8>, TowerClientError> {
    let status = response.status();
    let bytes = response.bytes()?;
    if !status.is_success() {
        return Err(TowerClientError::HttpStatus {
            status: status.as_u16(),
            body: String::from_utf8_lossy(&bytes).to_string(),
        });
    }
    Ok(bytes.to_vec())
}

fn header_to_string(headers: &HeaderMap, name: &str) -> Option<String> {
    headers
        .get(name)
        .and_then(|value| value.to_str().ok())
        .map(ToString::to_string)
}

#[allow(dead_code)]
fn encode_zero_event_cursor() -> String {
    URL_SAFE_NO_PAD.encode(r#"{"version":1,"rowVersion":0}"#)
}

#[cfg(test)]
mod tests {
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::thread;

    use reqwest::StatusCode;

    use super::*;

    fn test_key() -> DeviceKey {
        DeviceKey::from_hex("0000000000000000000000000000000000000000000000000000000000000001")
            .unwrap()
    }

    #[test]
    fn parses_drive_tree_items() {
        let json = r#"{
          "identity": {
            "tower_service_npub": null,
            "workspace_service_npub": null,
            "workspace_owner_npub": null,
            "workspace_id": "workspace-1",
            "app_npub": "npub-app"
          },
          "items": [
            {
              "type": "file",
              "id": "file-1",
              "workspace_id": "workspace-1",
              "scope_id": "scope-1",
              "channel_id": "channel-1",
              "parent_folder_id": null,
              "name": "report.pdf",
              "row_version": 4,
              "current_version_id": null,
              "storage_object_id": "object-1",
              "updated_at": "2026-07-01T00:00:00.000Z",
              "refetch": "/api/v4/flightdeck-pg/workspaces/workspace-1/files/file-1"
            }
          ],
          "next_cursor": null
        }"#;
        let parsed: DriveTreeResponse = serde_json::from_str(json).unwrap();
        assert_eq!(parsed.items.len(), 1);
        assert_eq!(parsed.items[0].item_type, DriveItemType::File);
        assert_eq!(parsed.items[0].name.as_deref(), Some("report.pdf"));
    }

    #[test]
    fn zero_event_cursor_matches_tower_shape() {
        assert_eq!(zero_event_cursor(), encode_zero_event_cursor());
    }

    #[test]
    fn signs_tower_requests_with_app_header() {
        let response = r#"{
          "identity": {
            "tower_service_npub": null,
            "workspace_service_npub": null,
            "workspace_owner_npub": null,
            "workspace_id": "workspace-1",
            "app_npub": "npub-app"
          },
          "items": [],
          "next_cursor": null
        }"#;
        let (base_url, handle) = spawn_one_response(response);
        let client = TowerClient::new(
            TowerClientConfig::new(base_url, "npub-app").unwrap(),
            test_key(),
        );

        let tree = client
            .drive_tree(
                "workspace-1",
                DriveTreeOptions {
                    channel_id: Some("channel-1"),
                    limit: Some(2),
                    ..DriveTreeOptions::default()
                },
            )
            .unwrap();
        assert!(tree.items.is_empty());

        let request = handle.join().unwrap();
        assert!(request.contains("get /api/v4/flightdeck-pg/workspaces/workspace-1/drive/tree?channel_id=channel-1&limit=2 http/1.1"));
        assert!(request.contains("authorization: nostr "));
        assert!(request.contains("x-flightdeck-pg-app-npub: npub-app"));
    }

    #[test]
    fn reads_single_channel_without_scope_scan() {
        let response = r#"{
          "identity": {
            "tower_service_npub": null,
            "workspace_service_npub": null,
            "workspace_owner_npub": null,
            "workspace_id": "workspace-1",
            "app_npub": "npub-app"
          },
          "channel": {
            "id": "channel-1",
            "workspace_id": "workspace-1",
            "scope_id": "scope-1",
            "name": "General",
            "description": null,
            "metadata": {},
            "kind": "channel",
            "participant_npubs": null,
            "row_version": 7,
            "created_at": "2026-07-01T00:00:00.000Z",
            "updated_at": "2026-07-01T00:00:00.000Z"
          }
        }"#;
        let (base_url, handle) = spawn_one_response(response);
        let client = TowerClient::new(
            TowerClientConfig::new(base_url, "npub-app").unwrap(),
            test_key(),
        );

        let channel = client.get_channel("workspace-1", "channel-1").unwrap();
        assert_eq!(channel.channel.name, "General");

        let request = handle.join().unwrap();
        assert!(request.contains(
            "get /api/v4/flightdeck-pg/workspaces/workspace-1/channels/channel-1 http/1.1"
        ));
    }

    #[test]
    fn registers_device_with_signed_json_body() {
        let response = r#"{
          "device": {
            "id": "npub-device",
            "device_npub": "npub-device",
            "user_npub": "npub-user",
            "workspace_owner_npub": "npub-workspace",
            "workspace_service_npub": "npub-workspace",
            "label": "MacBook",
            "platform": "macos",
            "policy": {"tower_nip98": true},
            "status": "active",
            "active": true,
            "last_seen_at": "2026-07-01T00:00:00.000Z",
            "revoked_at": null,
            "registered_at": "2026-07-01T00:00:00.000Z"
          }
        }"#;
        let (base_url, handle) = spawn_one_response(response);
        let client = TowerClient::new(
            TowerClientConfig::new(base_url, "npub-app").unwrap(),
            test_key(),
        );

        let registered = client
            .register_device(&RegisterDeviceRequest {
                workspace_service_npub: "npub-workspace".to_string(),
                device_npub: "npub-device".to_string(),
                label: Some("MacBook".to_string()),
                platform: Some("macos".to_string()),
                policy: serde_json::json!({ "tower_nip98": true }),
            })
            .unwrap();
        assert_eq!(registered.device.device_npub, "npub-device");

        let request = handle.join().unwrap();
        assert!(request.contains("post /api/v4/user/devices http/1.1"));
        assert!(request.contains("content-type: application/json"));
        assert!(request.contains("\"device_npub\":\"npub-device\""));
        assert!(request.contains("authorization: nostr "));
    }

    #[test]
    fn reads_ranged_file_object_bytes() {
        let (base_url, handle) = spawn_one_binary_response(b"hello".to_vec(), "bytes 0-4/11");
        let client = TowerClient::new(
            TowerClientConfig::new(base_url, "npub-app").unwrap(),
            test_key(),
        );

        let object = client
            .get_file_object_range("workspace-1", "file-1", ByteRange::bytes(0, 4))
            .unwrap();
        assert_eq!(object.status, StatusCode::PARTIAL_CONTENT.as_u16());
        assert_eq!(object.bytes, b"hello");
        assert_eq!(object.content_range.as_deref(), Some("bytes 0-4/11"));

        let request = handle.join().unwrap();
        assert!(request.contains("range: bytes=0-4"));
    }

    fn spawn_one_response(body: &'static str) -> (String, thread::JoinHandle<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let handle = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let request = read_request(&mut stream);
            let response = format!(
                "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\n\r\n{}",
                body.len(),
                body
            );
            stream.write_all(response.as_bytes()).unwrap();
            request
        });
        (format!("http://{addr}"), handle)
    }

    fn spawn_one_binary_response(
        body: Vec<u8>,
        content_range: &'static str,
    ) -> (String, thread::JoinHandle<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let handle = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let request = read_request(&mut stream);
            let header = format!(
                "HTTP/1.1 206 Partial Content\r\ncontent-type: application/octet-stream\r\ncontent-range: {content_range}\r\naccept-ranges: bytes\r\ncontent-length: {}\r\n\r\n",
                body.len()
            );
            stream.write_all(header.as_bytes()).unwrap();
            stream.write_all(&body).unwrap();
            request
        });
        (format!("http://{addr}"), handle)
    }

    fn read_request(stream: &mut std::net::TcpStream) -> String {
        let mut buffer = [0_u8; 4096];
        let count = stream.read(&mut buffer).unwrap();
        String::from_utf8_lossy(&buffer[..count]).to_ascii_lowercase()
    }
}
