use std::fs;
use std::io::{self, Write};
use std::path::PathBuf;
use std::sync::Mutex;

use clap::{Parser, Subcommand};
use serde::Serialize;
use wmapp_core::{
    DeviceKey, DeviceSeenRequest, DriveDeltaOptions, DriveItemType, DriveProjection,
    DriveTreeOptions, FuseMountConfig, Nip44Crypto, Nip98Request, Nip98Signer, NostrEventSigner,
    ObjectCache, ObjectCacheConfig, ObjectCacheError, ProjectionFileReader, RegisterDeviceRequest,
    SqliteIndex, SqliteIndexConfig, SyncEngine, TowerClient, TowerClientConfig, UnsignedNostrEvent,
    VisibleMetadata,
};

#[derive(Parser)]
#[command(name = "wmapp-core")]
#[command(about = "Wingman App native core development CLI")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Print native core status, optionally including live Tower and local index status.
    Status(StatusArgs),
    /// Run a one-shot Tower-to-local metadata sync.
    Sync(SyncArgs),
    /// List locally indexed Drive file/folder items.
    ListItems(ListItemsArgs),
    /// Read a file from cache, hydrating from Tower on cache miss when Tower config is present.
    Cat(CatArgs),
    /// Keep a cached file local.
    Pin(CacheFileArgs),
    /// Remove a cached file from local storage.
    Evict(EvictArgs),
    /// Inspect or start the read-only Drive mount projection.
    Mount(MountArgs),
    /// Validate a configured channel without scanning all scopes.
    Channel(ChannelArgs),
    /// List visible Drive file/folder items from Tower without persisting them.
    ListFiles(ListFilesArgs),
    /// Generate or inspect development device keys.
    Device {
        #[command(subcommand)]
        command: DeviceCommand,
    },
    /// Sign a NIP-98 HTTP authorization event.
    SignNip98 {
        #[arg(long)]
        secret: String,
        #[arg(long)]
        method: String,
        #[arg(long)]
        url: String,
        #[arg(long)]
        body: Option<String>,
    },
    /// Sign a NIP-07 style Nostr event template.
    SignEvent {
        #[arg(long)]
        secret: String,
        /// Unsigned event JSON. pubkey/id/sig are ignored and recomputed.
        #[arg(long)]
        event: String,
    },
    /// Run NIP-44 encryption or decryption with the local device key.
    Nip44 {
        #[command(subcommand)]
        command: Nip44Command,
    },
}

#[derive(Parser, Debug, Clone, Default)]
struct TowerReadArgs {
    /// Tower base URL. Falls back to TOWER_URL or FLIGHTDECK_TOWER_URL.
    #[arg(long)]
    tower_url: Option<String>,
    /// Flight Deck PG app npub. Falls back to FLIGHTDECK_APP_NPUB.
    #[arg(long)]
    app_npub: Option<String>,
    /// Hex or nsec key used for NIP-98 signing. Falls back to WINGMAN_NSEC, WINGMAN_PRIV, or AGENT_NSEC.
    #[arg(long)]
    secret: Option<String>,
}

#[derive(Parser, Debug, Clone, Default)]
struct LocalDataArgs {
    /// Local wmapp data directory. Falls back to WMAPP_DATA_DIR or ~/.wmapp.
    #[arg(long)]
    data_dir: Option<PathBuf>,
}

#[derive(Parser, Debug, Clone, Default)]
struct StatusArgs {
    #[command(flatten)]
    tower: TowerReadArgs,
    #[command(flatten)]
    local: LocalDataArgs,
    /// Optional workspace id for descriptor/me checks.
    #[arg(long)]
    workspace_id: Option<String>,
}

#[derive(Parser, Debug, Clone)]
struct SyncArgs {
    #[command(flatten)]
    tower: TowerReadArgs,
    #[command(flatten)]
    local: LocalDataArgs,
    /// Run a single foreground sync pass. Continuous sync is intentionally out of scope for WP-02-05.
    #[arg(long)]
    once: bool,
    /// Workspace id to sync.
    #[arg(long)]
    workspace_id: String,
    /// Optional scope filter.
    #[arg(long)]
    scope_id: Option<String>,
    /// Optional channel filter.
    #[arg(long)]
    channel_id: Option<String>,
    /// Optional parent folder filter.
    #[arg(long)]
    parent_folder_id: Option<String>,
    /// Page size.
    #[arg(long, default_value_t = 100)]
    limit: u16,
}

#[derive(Parser, Debug, Clone)]
struct ListItemsArgs {
    #[command(flatten)]
    local: LocalDataArgs,
    /// Workspace id to list from the local index.
    #[arg(long)]
    workspace_id: String,
}

#[derive(Parser, Debug, Clone)]
struct CatArgs {
    #[command(flatten)]
    tower: TowerReadArgs,
    #[command(flatten)]
    local: LocalDataArgs,
    /// Workspace id used for Tower hydration on cache miss.
    #[arg(long)]
    workspace_id: String,
    /// Write bytes to this file instead of stdout.
    #[arg(long)]
    output: Option<PathBuf>,
    /// File id to read.
    file_id: String,
}

#[derive(Parser, Debug, Clone)]
struct CacheFileArgs {
    #[command(flatten)]
    local: LocalDataArgs,
    /// File id to pin.
    file_id: String,
}

#[derive(Parser, Debug, Clone)]
struct EvictArgs {
    #[command(flatten)]
    local: LocalDataArgs,
    /// Evict even when the cache entry is pinned.
    #[arg(long)]
    force: bool,
    /// File id to evict.
    file_id: String,
}

#[derive(Parser, Debug, Clone)]
struct MountArgs {
    #[command(flatten)]
    tower: TowerReadArgs,
    #[command(flatten)]
    local: LocalDataArgs,
    /// Workspace id to project into a mounted tree.
    #[arg(long)]
    workspace_id: String,
    /// Mount point for the future FUSE/macFUSE mount.
    #[arg(long, default_value = "~/FlightDeck")]
    mountpoint: String,
    /// Print the projected tree without attempting a kernel mount.
    #[arg(long)]
    dry_run: bool,
}

#[derive(Parser, Debug, Clone)]
struct ChannelArgs {
    #[command(flatten)]
    tower: TowerReadArgs,
    /// Workspace id that owns the channel.
    #[arg(long)]
    workspace_id: String,
    /// Channel id to resolve.
    #[arg(long)]
    channel_id: String,
}

#[derive(Parser, Debug, Clone)]
struct ListFilesArgs {
    #[command(flatten)]
    tower: TowerReadArgs,
    /// Workspace id to list.
    #[arg(long)]
    workspace_id: String,
    /// Optional scope filter.
    #[arg(long)]
    scope_id: Option<String>,
    /// Optional channel filter.
    #[arg(long)]
    channel_id: Option<String>,
    /// Optional parent folder filter.
    #[arg(long)]
    parent_folder_id: Option<String>,
    /// Optional Drive tree cursor.
    #[arg(long)]
    cursor: Option<String>,
    /// Page size.
    #[arg(long, default_value_t = 100)]
    limit: u16,
}

#[derive(Subcommand)]
enum DeviceCommand {
    /// Generate a new local development device key.
    Generate {
        /// Include the nsec in output. Use only for development.
        #[arg(long)]
        show_secret: bool,
    },
    /// Import a hex or nsec key and print its public identity.
    Import {
        #[arg(long)]
        secret: String,
    },
    /// Register a device npub with Tower using the authenticated user signer.
    Register {
        #[command(flatten)]
        tower: TowerReadArgs,
        #[arg(long)]
        workspace_service_npub: String,
        #[arg(long)]
        device_npub: String,
        #[arg(long)]
        label: Option<String>,
        #[arg(long)]
        platform: Option<String>,
    },
    /// List registered devices for the authenticated user signer.
    List {
        #[command(flatten)]
        tower: TowerReadArgs,
    },
    /// Touch a registered device's last-seen timestamp.
    Seen {
        #[command(flatten)]
        tower: TowerReadArgs,
        #[arg(long)]
        workspace_service_npub: String,
        #[arg(long)]
        device_npub: String,
    },
    /// Revoke a registered device npub.
    Revoke {
        #[command(flatten)]
        tower: TowerReadArgs,
        #[arg(long)]
        device_npub: String,
    },
}

#[derive(Subcommand)]
enum Nip44Command {
    /// Encrypt plaintext to a peer x-only pubkey or npub.
    Encrypt {
        #[arg(long)]
        secret: String,
        #[arg(long)]
        peer_pubkey: String,
        #[arg(long)]
        plaintext: String,
    },
    /// Decrypt ciphertext from a peer x-only pubkey or npub.
    Decrypt {
        #[arg(long)]
        secret: String,
        #[arg(long)]
        peer_pubkey: String,
        #[arg(long)]
        ciphertext: String,
    },
}

#[derive(Serialize)]
struct DeviceOutput {
    npub: String,
    public_key_hex: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    nsec: Option<String>,
}

#[derive(Debug, Clone)]
struct LocalPaths {
    data_dir: PathBuf,
    db_path: PathBuf,
    cache_root: PathBuf,
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let cli = Cli::parse();
    match cli.command {
        Command::Status(args) => print_status(args)?,
        Command::Sync(args) => sync_once(args)?,
        Command::ListItems(args) => list_items(args)?,
        Command::Cat(args) => cat_file(args)?,
        Command::Pin(args) => pin_file(args)?,
        Command::Evict(args) => evict_file(args)?,
        Command::Mount(args) => mount_drive(args)?,
        Command::Channel(args) => validate_channel(args)?,
        Command::ListFiles(args) => list_files(args)?,
        Command::Device { command } => match command {
            DeviceCommand::Generate { show_secret } => {
                let key = DeviceKey::generate();
                print_device(&key, show_secret)?;
            }
            DeviceCommand::Import { secret } => {
                let key = DeviceKey::import(&secret)?;
                print_device(&key, false)?;
            }
            DeviceCommand::Register {
                tower,
                workspace_service_npub,
                device_npub,
                label,
                platform,
            } => register_device(tower, workspace_service_npub, device_npub, label, platform)?,
            DeviceCommand::List { tower } => list_devices(tower)?,
            DeviceCommand::Seen {
                tower,
                workspace_service_npub,
                device_npub,
            } => touch_device_seen(tower, workspace_service_npub, device_npub)?,
            DeviceCommand::Revoke { tower, device_npub } => revoke_device(tower, device_npub)?,
        },
        Command::SignNip98 {
            secret,
            method,
            url,
            body,
        } => {
            let key = DeviceKey::import(&secret)?;
            let mut request = Nip98Request::new(method, url)?;
            if let Some(body) = body {
                request = request.with_body(body.into_bytes());
            }
            let event = Nip98Signer::new(key).sign(request)?;
            print_json(&serde_json::json!({
                "authorization": event.authorization_header()?,
                "event": event
            }))?;
        }
        Command::SignEvent { secret, event } => {
            let key = DeviceKey::import(&secret)?;
            let unsigned: UnsignedNostrEvent = serde_json::from_str(&event)?;
            let signed = NostrEventSigner::new(key).sign(unsigned)?;
            print_json(&signed)?;
        }
        Command::Nip44 { command } => match command {
            Nip44Command::Encrypt {
                secret,
                peer_pubkey,
                plaintext,
            } => {
                let key = DeviceKey::import(&secret)?;
                let ciphertext = Nip44Crypto::new(key).encrypt(&peer_pubkey, &plaintext)?;
                print_json(&serde_json::json!({ "ciphertext": ciphertext }))?;
            }
            Nip44Command::Decrypt {
                secret,
                peer_pubkey,
                ciphertext,
            } => {
                let key = DeviceKey::import(&secret)?;
                let plaintext = Nip44Crypto::new(key).decrypt(&peer_pubkey, &ciphertext)?;
                print_json(&serde_json::json!({ "plaintext": plaintext }))?;
            }
        },
    }
    Ok(())
}

fn print_status(args: StatusArgs) -> Result<(), Box<dyn std::error::Error>> {
    let local = local_paths(&args.local)?;
    let local_status = match SqliteIndex::open(SqliteIndexConfig {
        path: local.db_path.clone(),
    }) {
        Ok(index) => serde_json::json!({
            "data_dir": local.data_dir,
            "db_path": index.path(),
            "cache_root": local.cache_root,
            "schema_version": index.schema_version()?,
        }),
        Err(error) => serde_json::json!({
            "data_dir": local.data_dir,
            "db_path": local.db_path,
            "cache_root": local.cache_root,
            "error": error.to_string(),
        }),
    };

    match tower_client_from_args(&args.tower, false)? {
        Some(client) => {
            let service = client.service()?;
            let workspaces = client.list_workspaces()?;
            let mut workspace = None;
            let mut me = None;
            if let Some(workspace_id) = args.workspace_id.as_deref() {
                workspace = Some(client.workspace_descriptor(workspace_id)?);
                me = Some(client.workspace_me(workspace_id)?);
            }
            print_json(&serde_json::json!({
                "ok": true,
                "crate": "wmapp-core",
                "phase": "native-core-spike",
                "local": local_status,
                "tower": {
                    "url": client.config().tower_url.as_str(),
                    "app_npub": client.config().app_npub,
                    "signer_public_key_hex": client.signer_public_key_hex(),
                    "service": service.service,
                    "capabilities": service.capabilities,
                    "workspace_count": workspaces.workspaces.len(),
                    "workspaces": workspaces.workspaces,
                    "workspace": workspace,
                    "me": me
                }
            }))?;
        }
        None => {
            print_json(&serde_json::json!({
                "ok": true,
                "crate": "wmapp-core",
                "phase": "native-core-spike",
                "local": local_status,
                "tower": {
                    "configured": false,
                    "missing": ["tower_url", "app_npub", "secret"]
                }
            }))?;
        }
    }
    Ok(())
}

fn sync_once(args: SyncArgs) -> Result<(), Box<dyn std::error::Error>> {
    if !args.once {
        return Err("only sync --once is supported in WP-02-05".into());
    }
    let client =
        tower_client_from_args(&args.tower, true)?.ok_or("Tower config is required for sync")?;
    let local = local_paths(&args.local)?;
    let index = open_index(&local)?;

    let workspaces = client.list_workspaces()?;
    let descriptor = client.workspace_descriptor(&args.workspace_id)?;
    let me = client.workspace_me(&args.workspace_id)?;
    let scopes_response = client.list_scopes(&args.workspace_id)?;
    let scopes: Vec<_> = scopes_response
        .scopes
        .into_iter()
        .filter(|scope| {
            args.scope_id
                .as_deref()
                .map(|scope_id| scope.id == scope_id)
                .unwrap_or(true)
        })
        .collect();

    let mut channels = Vec::new();
    for scope in &scopes {
        let response = client.list_channels(&args.workspace_id, &scope.id, Some(args.limit))?;
        channels.extend(response.channels.into_iter().filter(|channel| {
            args.channel_id
                .as_deref()
                .map(|channel_id| channel.id == channel_id)
                .unwrap_or(true)
        }));
    }

    let previous_delta_cursor = index.get_cursor(
        &args.workspace_id,
        "drive_delta",
        args.scope_id.as_deref(),
        args.channel_id.as_deref(),
    )?;
    let tree = client.drive_tree(
        &args.workspace_id,
        DriveTreeOptions {
            scope_id: args.scope_id.as_deref(),
            channel_id: args.channel_id.as_deref(),
            parent_folder_id: args.parent_folder_id.as_deref(),
            cursor: None,
            limit: Some(args.limit),
        },
    )?;
    let delta = client.drive_delta(
        &args.workspace_id,
        DriveDeltaOptions {
            scope_id: args.scope_id.as_deref(),
            channel_id: args.channel_id.as_deref(),
            cursor: previous_delta_cursor.as_deref(),
            limit: Some(args.limit),
        },
    )?;

    let summary = SyncEngine::new().persist_visible_metadata(
        &index,
        VisibleMetadata {
            workspace_summaries: &workspaces.workspaces,
            workspace_descriptor: Some(&descriptor),
            workspace_me: Some(&me),
            scopes: &scopes,
            channels: &channels,
            drive_tree: Some(&tree),
            drive_delta: Some(&delta),
        },
    )?;
    index.put_cursor(
        &args.workspace_id,
        "drive_tree",
        args.scope_id.as_deref(),
        args.channel_id.as_deref(),
        tree.next_cursor.as_deref(),
        tree.items.iter().map(|item| item.row_version).max(),
    )?;
    index.put_cursor(
        &args.workspace_id,
        "drive_delta",
        args.scope_id.as_deref(),
        args.channel_id.as_deref(),
        delta.next_cursor.as_deref(),
        delta
            .changes
            .iter()
            .map(|change| change.event_row_version)
            .max(),
    )?;
    let items = index.list_items(&args.workspace_id)?;
    print_json(&serde_json::json!({
        "ok": true,
        "workspace_id": args.workspace_id,
        "scope_id": args.scope_id,
        "channel_id": args.channel_id,
        "parent_folder_id": args.parent_folder_id,
        "data_dir": local.data_dir,
        "db_path": local.db_path,
        "cache_root": local.cache_root,
        "summary": summary,
        "local_item_count": items.len(),
        "tree_next_cursor": tree.next_cursor,
        "delta_next_cursor": delta.next_cursor,
    }))?;
    Ok(())
}

fn list_items(args: ListItemsArgs) -> Result<(), Box<dyn std::error::Error>> {
    let local = local_paths(&args.local)?;
    let index = open_index(&local)?;
    let items = index.list_items(&args.workspace_id)?;
    let file_count = items.iter().filter(|item| item.item_type == "file").count();
    let folder_count = items
        .iter()
        .filter(|item| item.item_type == "folder")
        .count();
    print_json(&serde_json::json!({
        "ok": true,
        "workspace_id": args.workspace_id,
        "data_dir": local.data_dir,
        "db_path": local.db_path,
        "file_count": file_count,
        "folder_count": folder_count,
        "items": items,
    }))?;
    Ok(())
}

fn cat_file(args: CatArgs) -> Result<(), Box<dyn std::error::Error>> {
    let local = local_paths(&args.local)?;
    let index = open_index(&local)?;
    let cache = open_cache(&local)?;

    let (bytes, source) = match cache.read_file(&index, &args.file_id) {
        Ok(bytes) => (bytes, "cache"),
        Err(ObjectCacheError::MissingEntry(_)) => {
            let client = tower_client_from_args(&args.tower, true)?
                .ok_or("Tower config is required to hydrate an uncached file")?;
            let object = client.get_file_object(&args.workspace_id, &args.file_id)?;
            cache.put_file_object(&index, &object)?;
            (cache.read_file(&index, &args.file_id)?, "tower")
        }
        Err(error) => return Err(Box::new(error)),
    };

    if let Some(output) = args.output {
        if let Some(parent) = output.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(&output, &bytes)?;
        print_json(&serde_json::json!({
            "ok": true,
            "workspace_id": args.workspace_id,
            "file_id": args.file_id,
            "source": source,
            "output": output,
            "bytes": bytes.len(),
        }))?;
    } else {
        io::stdout().write_all(&bytes)?;
    }
    Ok(())
}

fn pin_file(args: CacheFileArgs) -> Result<(), Box<dyn std::error::Error>> {
    let local = local_paths(&args.local)?;
    let index = open_index(&local)?;
    let cache = open_cache(&local)?;
    let entry = cache.set_pinned(&index, &args.file_id, true)?;
    print_json(&serde_json::json!({
        "ok": true,
        "file_id": args.file_id,
        "entry": entry,
    }))?;
    Ok(())
}

fn evict_file(args: EvictArgs) -> Result<(), Box<dyn std::error::Error>> {
    let local = local_paths(&args.local)?;
    let index = open_index(&local)?;
    let cache = open_cache(&local)?;
    let entry = cache.evict_file(&index, &args.file_id, args.force)?;
    print_json(&serde_json::json!({
        "ok": true,
        "file_id": args.file_id,
        "evicted": entry,
        "forced": args.force,
    }))?;
    Ok(())
}

fn mount_drive(args: MountArgs) -> Result<(), Box<dyn std::error::Error>> {
    let local = local_paths(&args.local)?;
    let index = open_index(&local)?;
    let projection = DriveProjection::from_index(&index, &args.workspace_id)?;
    let mountpoint = expand_home(&args.mountpoint);

    if args.dry_run {
        print_json(&serde_json::json!({
            "ok": true,
            "mode": "dry_run",
            "platform": std::env::consts::OS,
            "mountpoint": mountpoint,
            "workspace_id": args.workspace_id,
            "data_dir": local.data_dir,
            "entry_count": projection.entries.len(),
            "entries": projection.entries,
            "warnings": projection.warnings,
        }))?;
        return Ok(());
    }

    eprintln!(
        "mounting read-only Wingman Drive projection at {}. Keep this process running; unmount from another shell when finished.",
        mountpoint.display()
    );
    let client = tower_client_from_args(&args.tower, false)?;
    let file_reader = std::sync::Arc::new(MountFileReader {
        local: local.clone(),
        workspace_id: args.workspace_id.clone(),
        client: client.map(Mutex::new),
    });

    wmapp_core::mount_read_only_projection_with_reader(
        projection,
        FuseMountConfig {
            mountpoint,
            fs_name: format!("wmapp-{}", args.workspace_id),
        },
        file_reader,
    )?;
    Ok(())
}

struct MountFileReader {
    local: LocalPaths,
    workspace_id: String,
    client: Option<Mutex<TowerClient>>,
}

impl ProjectionFileReader for MountFileReader {
    fn read_file(&self, file_id: &str) -> io::Result<Vec<u8>> {
        let index = SqliteIndex::open(SqliteIndexConfig {
            path: self.local.db_path.clone(),
        })
        .map_err(io::Error::other)?;
        let cache = ObjectCache::open(ObjectCacheConfig {
            root: self.local.cache_root.clone(),
        })
        .map_err(io::Error::other)?;

        match cache.read_file(&index, file_id) {
            Ok(bytes) => return Ok(bytes),
            Err(ObjectCacheError::MissingEntry(_)) => {}
            Err(error) => return Err(io::Error::other(error)),
        }

        let Some(client) = &self.client else {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                format!("file {file_id} is not cached and Tower config is unavailable"),
            ));
        };
        let object = client
            .lock()
            .map_err(|_| io::Error::other("Tower client lock poisoned"))?
            .get_file_object(&self.workspace_id, file_id)
            .map_err(io::Error::other)?;
        cache
            .put_file_object(&index, &object)
            .map_err(io::Error::other)?;
        cache.read_file(&index, file_id).map_err(io::Error::other)
    }
}

fn validate_channel(args: ChannelArgs) -> Result<(), Box<dyn std::error::Error>> {
    let client = tower_client_from_args(&args.tower, true)?
        .ok_or("Tower config is required for channel validation")?;
    let response = client.get_channel(&args.workspace_id, &args.channel_id)?;
    print_json(&serde_json::json!({
        "ok": true,
        "workspace_id": args.workspace_id,
        "channel_id": args.channel_id,
        "channel": response.channel,
    }))?;
    Ok(())
}

fn list_files(args: ListFilesArgs) -> Result<(), Box<dyn std::error::Error>> {
    let client = tower_client_from_args(&args.tower, true)?
        .ok_or("Tower config is required for list-files")?;
    let tree = client.drive_tree(
        &args.workspace_id,
        DriveTreeOptions {
            scope_id: args.scope_id.as_deref(),
            channel_id: args.channel_id.as_deref(),
            parent_folder_id: args.parent_folder_id.as_deref(),
            cursor: args.cursor.as_deref(),
            limit: Some(args.limit),
        },
    )?;
    let file_count = tree
        .items
        .iter()
        .filter(|item| item.item_type == DriveItemType::File)
        .count();
    let folder_count = tree
        .items
        .iter()
        .filter(|item| item.item_type == DriveItemType::Folder)
        .count();
    print_json(&serde_json::json!({
        "ok": true,
        "workspace_id": args.workspace_id,
        "scope_id": args.scope_id,
        "channel_id": args.channel_id,
        "parent_folder_id": args.parent_folder_id,
        "file_count": file_count,
        "folder_count": folder_count,
        "items": tree.items,
        "next_cursor": tree.next_cursor
    }))?;
    Ok(())
}

fn register_device(
    tower: TowerReadArgs,
    workspace_service_npub: String,
    device_npub: String,
    label: Option<String>,
    platform: Option<String>,
) -> Result<(), Box<dyn std::error::Error>> {
    let client = tower_client_from_args(&tower, true)?
        .ok_or("Tower config is required for device register")?;
    let response = client.register_device(&RegisterDeviceRequest {
        workspace_service_npub,
        device_npub,
        label,
        platform,
        policy: serde_json::json!({
            "tower_nip98": true,
            "wapp_nip98": true,
            "requires_prompt_for": ["signEvent", "nip04.decrypt", "nip44.decrypt"]
        }),
    })?;
    print_json(&serde_json::json!({
        "ok": true,
        "device": response.device,
    }))?;
    Ok(())
}

fn list_devices(tower: TowerReadArgs) -> Result<(), Box<dyn std::error::Error>> {
    let client =
        tower_client_from_args(&tower, true)?.ok_or("Tower config is required for device list")?;
    let response = client.list_devices()?;
    print_json(&serde_json::json!({
        "ok": true,
        "devices": response.devices,
    }))?;
    Ok(())
}

fn touch_device_seen(
    tower: TowerReadArgs,
    workspace_service_npub: String,
    device_npub: String,
) -> Result<(), Box<dyn std::error::Error>> {
    let client =
        tower_client_from_args(&tower, true)?.ok_or("Tower config is required for device seen")?;
    let response = client.touch_device_seen(
        &device_npub,
        &DeviceSeenRequest {
            workspace_service_npub,
        },
    )?;
    print_json(&serde_json::json!({
        "ok": true,
        "device": response.device,
    }))?;
    Ok(())
}

fn revoke_device(
    tower: TowerReadArgs,
    device_npub: String,
) -> Result<(), Box<dyn std::error::Error>> {
    let client = tower_client_from_args(&tower, true)?
        .ok_or("Tower config is required for device revoke")?;
    let response = client.revoke_device(&device_npub)?;
    print_json(&serde_json::json!({
        "ok": true,
        "device": response.device,
    }))?;
    Ok(())
}

fn print_device(key: &DeviceKey, show_secret: bool) -> Result<(), Box<dyn std::error::Error>> {
    print_json(&DeviceOutput {
        npub: key.npub()?,
        public_key_hex: key.public_key_hex(),
        nsec: if show_secret { Some(key.nsec()?) } else { None },
    })
}

fn print_json<T: Serialize>(value: &T) -> Result<(), Box<dyn std::error::Error>> {
    println!("{}", serde_json::to_string_pretty(value)?);
    Ok(())
}

fn open_index(local: &LocalPaths) -> Result<SqliteIndex, Box<dyn std::error::Error>> {
    if let Some(parent) = local.db_path.parent() {
        fs::create_dir_all(parent)?;
    }
    Ok(SqliteIndex::open(SqliteIndexConfig {
        path: local.db_path.clone(),
    })?)
}

fn open_cache(local: &LocalPaths) -> Result<ObjectCache, Box<dyn std::error::Error>> {
    Ok(ObjectCache::open(ObjectCacheConfig {
        root: local.cache_root.clone(),
    })?)
}

fn local_paths(args: &LocalDataArgs) -> Result<LocalPaths, Box<dyn std::error::Error>> {
    let data_dir = args
        .data_dir
        .clone()
        .or_else(|| std::env::var_os("WMAPP_DATA_DIR").map(PathBuf::from))
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".wmapp")))
        .ok_or("missing data directory; pass --data-dir or set WMAPP_DATA_DIR")?;
    Ok(LocalPaths {
        db_path: data_dir.join("index.sqlite"),
        cache_root: data_dir.join("cache"),
        data_dir,
    })
}

fn expand_home(path: &str) -> PathBuf {
    if let Some(rest) = path.strip_prefix("~/") {
        if let Some(home) = std::env::var_os("HOME") {
            return PathBuf::from(home).join(rest);
        }
    }
    PathBuf::from(path)
}

fn tower_client_from_args(
    args: &TowerReadArgs,
    required: bool,
) -> Result<Option<TowerClient>, Box<dyn std::error::Error>> {
    let tower_url = args
        .tower_url
        .clone()
        .or_else(|| std::env::var("TOWER_URL").ok())
        .or_else(|| std::env::var("FLIGHTDECK_TOWER_URL").ok());
    let app_npub = args
        .app_npub
        .clone()
        .or_else(|| std::env::var("FLIGHTDECK_APP_NPUB").ok());
    let secret = args
        .secret
        .clone()
        .or_else(|| std::env::var("WINGMAN_NSEC").ok())
        .or_else(|| std::env::var("WINGMAN_PRIV").ok())
        .or_else(|| std::env::var("AGENT_NSEC").ok());

    if tower_url.is_none() && app_npub.is_none() && secret.is_none() && !required {
        return Ok(None);
    }

    let tower_url = tower_url.ok_or("missing Tower URL; pass --tower-url or set TOWER_URL")?;
    let app_npub =
        app_npub.ok_or("missing app npub; pass --app-npub or set FLIGHTDECK_APP_NPUB")?;
    let secret = secret.ok_or("missing signing key; pass --secret or set WINGMAN_NSEC")?;
    let key = DeviceKey::import(&secret)?;
    let config = TowerClientConfig::new(tower_url, app_npub)?;
    Ok(Some(TowerClient::new(config, key)))
}
