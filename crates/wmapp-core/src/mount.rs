use std::collections::BTreeMap;
use std::ffi::OsStr;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use fuser::{
    Config, Errno, FileAttr, FileHandle, FileType, Filesystem, FopenFlags, Generation, INodeNo,
    LockOwner, MountOption, OpenAccMode, OpenFlags, ReplyAttr, ReplyData, ReplyDirectory,
    ReplyEmpty, ReplyEntry, ReplyOpen, Request,
};
use thiserror::Error;

use crate::{DriveProjection, ProjectedEntryKind};

const ROOT_INO: u64 = 1;
const TTL: Duration = Duration::from_secs(1);
const UNKNOWN_ONLINE_FILE_SIZE: u64 = 1024 * 1024;

#[derive(Debug, Error)]
pub enum FuseMountError {
    #[error("mountpoint exists but is not a directory: {0}")]
    MountpointNotDirectory(PathBuf),
    #[error("mountpoint setup failed for {path}: {source}")]
    MountpointSetup {
        path: PathBuf,
        source: std::io::Error,
    },
    #[cfg(target_os = "macos")]
    #[error("macFUSE kernel device is unavailable: {detail}")]
    MacFuseUnavailable { detail: String },
    #[error("FUSE mount failed for {path}: {source}. On macOS verify macFUSE is approved and /Library/Filesystems/macfuse.fs/Contents/Resources/mount_macfuse is usable; on Linux verify /dev/fuse access")]
    Mount {
        path: PathBuf,
        source: std::io::Error,
    },
}

#[derive(Debug, Clone)]
pub struct FuseMountConfig {
    pub mountpoint: PathBuf,
    pub fs_name: String,
}

pub trait ProjectionFileReader: Send + Sync {
    fn read_file(&self, file_id: &str) -> io::Result<Vec<u8>>;
}

#[derive(Debug)]
struct EmptyFileReader;

impl ProjectionFileReader for EmptyFileReader {
    fn read_file(&self, _file_id: &str) -> io::Result<Vec<u8>> {
        Ok(Vec::new())
    }
}

pub fn mount_read_only_projection(
    projection: DriveProjection,
    config: FuseMountConfig,
) -> Result<(), FuseMountError> {
    mount_read_only_projection_with_reader(projection, config, Arc::new(EmptyFileReader))
}

pub fn mount_read_only_projection_with_reader(
    projection: DriveProjection,
    config: FuseMountConfig,
    file_reader: Arc<dyn ProjectionFileReader>,
) -> Result<(), FuseMountError> {
    ensure_mountpoint(&config.mountpoint)?;
    preflight_mount_host()?;
    let fs = ProjectionFileSystem::new(projection, file_reader);
    let mut mount_config = Config::default();
    mount_config.mount_options.extend([
        MountOption::RO,
        MountOption::NoDev,
        MountOption::NoSuid,
        MountOption::NoExec,
        MountOption::FSName(config.fs_name),
        MountOption::Subtype("wmapp".to_string()),
    ]);
    fuser::mount2(fs, &config.mountpoint, &mount_config).map_err(|source| FuseMountError::Mount {
        path: config.mountpoint,
        source,
    })
}

#[cfg(target_os = "macos")]
fn preflight_mount_host() -> Result<(), FuseMountError> {
    if has_macos_fuse_device() {
        return Ok(());
    }

    let loader = Path::new("/Library/Filesystems/macfuse.fs/Contents/Resources/load_macfuse");
    if !loader.exists() {
        return Err(FuseMountError::MacFuseUnavailable {
            detail: format!("{} is missing", loader.display()),
        });
    }

    let output =
        Command::new(loader)
            .output()
            .map_err(|source| FuseMountError::MacFuseUnavailable {
                detail: format!("failed to run {}: {source}", loader.display()),
            })?;
    if has_macos_fuse_device() {
        return Ok(());
    }

    Err(FuseMountError::MacFuseUnavailable {
        detail: format!(
            "{} exited with status {}; stdout: {}; stderr: {}; no /dev/macfuse*, /dev/osxfuse*, or /dev/fuse* device is present",
            loader.display(),
            output.status,
            String::from_utf8_lossy(&output.stdout).trim(),
            String::from_utf8_lossy(&output.stderr).trim()
        ),
    })
}

#[cfg(target_os = "macos")]
fn has_macos_fuse_device() -> bool {
    let Ok(entries) = fs::read_dir("/dev") else {
        return false;
    };
    entries.filter_map(Result::ok).any(|entry| {
        entry
            .file_name()
            .to_str()
            .map(|name| {
                name.starts_with("macfuse")
                    || name.starts_with("osxfuse")
                    || name == "fuse"
                    || name.starts_with("fuse.")
            })
            .unwrap_or(false)
    })
}

#[cfg(not(target_os = "macos"))]
fn preflight_mount_host() -> Result<(), FuseMountError> {
    Ok(())
}

fn ensure_mountpoint(path: &Path) -> Result<(), FuseMountError> {
    if path.exists() {
        if path.is_dir() {
            return Ok(());
        }
        return Err(FuseMountError::MountpointNotDirectory(path.to_path_buf()));
    }
    fs::create_dir_all(path).map_err(|source| FuseMountError::MountpointSetup {
        path: path.to_path_buf(),
        source,
    })
}

struct ProjectionFileSystem {
    tree: ProjectionTree,
    file_reader: Arc<dyn ProjectionFileReader>,
}

impl ProjectionFileSystem {
    fn new(projection: DriveProjection, file_reader: Arc<dyn ProjectionFileReader>) -> Self {
        Self {
            tree: ProjectionTree::from_projection(projection),
            file_reader,
        }
    }
}

impl Filesystem for ProjectionFileSystem {
    fn lookup(&self, _req: &Request, parent: INodeNo, name: &OsStr, reply: ReplyEntry) {
        let Some(name) = name.to_str() else {
            reply.error(Errno::ENOENT);
            return;
        };
        match self.tree.lookup(u64::from(parent), name) {
            Some(node) => reply.entry(&TTL, &self.tree.attr(node), Generation(0)),
            None => reply.error(Errno::ENOENT),
        }
    }

    fn getattr(&self, _req: &Request, ino: INodeNo, _fh: Option<FileHandle>, reply: ReplyAttr) {
        match self.tree.node(u64::from(ino)) {
            Some(node) => reply.attr(&TTL, &self.tree.attr(node)),
            None => reply.error(Errno::ENOENT),
        }
    }

    fn opendir(&self, _req: &Request, ino: INodeNo, _flags: OpenFlags, reply: ReplyOpen) {
        match self.tree.node(u64::from(ino)) {
            Some(node) if node.kind == NodeKind::Directory => {
                reply.opened(FileHandle(0), FopenFlags::empty())
            }
            Some(_) => reply.error(Errno::ENOTDIR),
            None => reply.error(Errno::ENOENT),
        }
    }

    fn readdir(
        &self,
        _req: &Request,
        ino: INodeNo,
        _fh: FileHandle,
        offset: u64,
        mut reply: ReplyDirectory,
    ) {
        let Some(entries) = self.tree.directory_entries(u64::from(ino)) else {
            reply.error(Errno::ENOENT);
            return;
        };
        for (index, entry) in entries.into_iter().enumerate().skip(offset as usize) {
            if reply.add(
                INodeNo(entry.ino),
                (index + 1) as u64,
                entry.kind.file_type(),
                entry.name,
            ) {
                break;
            }
        }
        reply.ok();
    }

    fn open(&self, _req: &Request, ino: INodeNo, flags: OpenFlags, reply: ReplyOpen) {
        let Some(node) = self.tree.node(u64::from(ino)) else {
            reply.error(Errno::ENOENT);
            return;
        };
        if node.kind != NodeKind::File {
            reply.error(Errno::EISDIR);
            return;
        }
        match flags.acc_mode() {
            OpenAccMode::O_RDONLY => reply.opened(FileHandle(0), FopenFlags::empty()),
            OpenAccMode::O_WRONLY | OpenAccMode::O_RDWR => reply.error(Errno::EROFS),
        }
    }

    fn read(
        &self,
        _req: &Request,
        ino: INodeNo,
        _fh: FileHandle,
        offset: u64,
        size: u32,
        _flags: OpenFlags,
        _lock_owner: Option<LockOwner>,
        reply: ReplyData,
    ) {
        let Some(node) = self.tree.node(u64::from(ino)) else {
            reply.error(Errno::ENOENT);
            return;
        };
        if node.kind != NodeKind::File {
            reply.error(Errno::EISDIR);
            return;
        }
        let Some(file_id) = node.file_id.as_deref() else {
            reply.error(Errno::EIO);
            return;
        };
        let content = match self.file_reader.read_file(file_id) {
            Ok(content) => content,
            Err(_) => {
                reply.error(Errno::EIO);
                return;
            }
        };
        let start = offset.min(content.len() as u64) as usize;
        let end = (start + size as usize).min(content.len());
        reply.data(&content[start..end]);
    }

    fn mkdir(
        &self,
        _req: &Request,
        _parent: INodeNo,
        _name: &OsStr,
        _mode: u32,
        _umask: u32,
        reply: ReplyEntry,
    ) {
        reply.error(Errno::EROFS);
    }

    fn mknod(
        &self,
        _req: &Request,
        _parent: INodeNo,
        _name: &OsStr,
        _mode: u32,
        _umask: u32,
        _rdev: u32,
        reply: ReplyEntry,
    ) {
        reply.error(Errno::EROFS);
    }

    fn unlink(&self, _req: &Request, _parent: INodeNo, _name: &OsStr, reply: ReplyEmpty) {
        reply.error(Errno::EROFS);
    }

    fn rmdir(&self, _req: &Request, _parent: INodeNo, _name: &OsStr, reply: ReplyEmpty) {
        reply.error(Errno::EROFS);
    }

    fn rename(
        &self,
        _req: &Request,
        _parent: INodeNo,
        _name: &OsStr,
        _newparent: INodeNo,
        _newname: &OsStr,
        _flags: fuser::RenameFlags,
        reply: ReplyEmpty,
    ) {
        reply.error(Errno::EROFS);
    }
}

#[derive(Debug)]
struct ProjectionTree {
    nodes: Vec<Node>,
    by_ino: BTreeMap<u64, usize>,
}

impl ProjectionTree {
    fn from_projection(projection: DriveProjection) -> Self {
        let mut tree = Self {
            nodes: vec![Node::root()],
            by_ino: BTreeMap::from([(ROOT_INO, 0)]),
        };
        for entry in projection.entries {
            let components = entry
                .path
                .split('/')
                .filter(|component| !component.is_empty())
                .collect::<Vec<_>>();
            if components.is_empty() {
                continue;
            }
            let mut parent = ROOT_INO;
            for (index, component) in components.iter().enumerate() {
                let is_leaf = index + 1 == components.len();
                let kind = if is_leaf && entry.kind == ProjectedEntryKind::File {
                    NodeKind::File
                } else {
                    NodeKind::Directory
                };
                let child = tree.ensure_child(parent, component, kind);
                if is_leaf && kind == NodeKind::File {
                    tree.set_file_metadata(
                        child,
                        entry.file_id.clone(),
                        entry.storage_object_id.clone(),
                        entry.local_state.clone(),
                        entry.size_bytes,
                    );
                }
                parent = child;
            }
        }
        tree
    }

    fn node(&self, ino: u64) -> Option<&Node> {
        self.by_ino
            .get(&ino)
            .and_then(|index| self.nodes.get(*index))
    }

    fn lookup(&self, parent: u64, name: &str) -> Option<&Node> {
        let ino = self.node(parent)?.children.get(name)?;
        self.node(*ino)
    }

    fn directory_entries(&self, ino: u64) -> Option<Vec<DirectoryEntry>> {
        let node = self.node(ino)?;
        if node.kind != NodeKind::Directory {
            return None;
        }
        let parent = self.node(node.parent).unwrap_or(node);
        let mut entries = vec![
            DirectoryEntry {
                ino: node.ino,
                kind: NodeKind::Directory,
                name: ".".to_string(),
            },
            DirectoryEntry {
                ino: parent.ino,
                kind: NodeKind::Directory,
                name: "..".to_string(),
            },
        ];
        entries.extend(node.children.iter().filter_map(|(name, child_ino)| {
            self.node(*child_ino).map(|child| DirectoryEntry {
                ino: child.ino,
                kind: child.kind,
                name: name.clone(),
            })
        }));
        Some(entries)
    }

    fn attr(&self, node: &Node) -> FileAttr {
        FileAttr {
            ino: INodeNo(node.ino),
            size: node.size_bytes.unwrap_or_else(|| {
                if node.kind == NodeKind::File {
                    UNKNOWN_ONLINE_FILE_SIZE
                } else {
                    0
                }
            }),
            blocks: node.size_bytes.map(|size| size.div_ceil(512)).unwrap_or(0),
            atime: UNIX_EPOCH,
            mtime: node.mtime,
            ctime: node.mtime,
            crtime: node.mtime,
            kind: node.kind.file_type(),
            perm: node.kind.perm(),
            nlink: if node.kind == NodeKind::Directory {
                2 + node
                    .children
                    .values()
                    .filter_map(|ino| self.node(*ino))
                    .filter(|child| child.kind == NodeKind::Directory)
                    .count() as u32
            } else {
                1
            },
            uid: current_uid(),
            gid: current_gid(),
            rdev: 0,
            blksize: 512,
            flags: 0,
        }
    }

    fn ensure_child(&mut self, parent_ino: u64, name: &str, kind: NodeKind) -> u64 {
        if let Some(existing) = self
            .node(parent_ino)
            .and_then(|parent| parent.children.get(name))
            .copied()
        {
            return existing;
        }
        let ino = ROOT_INO + self.nodes.len() as u64;
        let node = Node {
            ino,
            parent: parent_ino,
            name: name.to_string(),
            kind,
            children: BTreeMap::new(),
            file_id: None,
            storage_object_id: None,
            local_state: None,
            size_bytes: None,
            mtime: SystemTime::now(),
        };
        self.nodes.push(node);
        self.by_ino.insert(ino, self.nodes.len() - 1);
        if let Some(parent_index) = self.by_ino.get(&parent_ino).copied() {
            self.nodes[parent_index]
                .children
                .insert(name.to_string(), ino);
        }
        ino
    }

    fn set_file_metadata(
        &mut self,
        ino: u64,
        file_id: Option<String>,
        storage_object_id: Option<String>,
        local_state: Option<String>,
        size_bytes: Option<u64>,
    ) {
        let Some(index) = self.by_ino.get(&ino).copied() else {
            return;
        };
        let node = &mut self.nodes[index];
        node.file_id = file_id;
        node.storage_object_id = storage_object_id;
        node.local_state = local_state;
        node.size_bytes = size_bytes;
    }
}

#[derive(Debug)]
struct DirectoryEntry {
    ino: u64,
    kind: NodeKind,
    name: String,
}

#[derive(Debug)]
struct Node {
    ino: u64,
    parent: u64,
    #[allow(dead_code)]
    name: String,
    kind: NodeKind,
    children: BTreeMap<String, u64>,
    file_id: Option<String>,
    storage_object_id: Option<String>,
    local_state: Option<String>,
    size_bytes: Option<u64>,
    mtime: SystemTime,
}

impl Node {
    fn root() -> Self {
        Self {
            ino: ROOT_INO,
            parent: ROOT_INO,
            name: String::new(),
            kind: NodeKind::Directory,
            children: BTreeMap::new(),
            file_id: None,
            storage_object_id: None,
            local_state: None,
            size_bytes: None,
            mtime: UNIX_EPOCH,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum NodeKind {
    Directory,
    File,
}

impl NodeKind {
    fn file_type(self) -> FileType {
        match self {
            Self::Directory => FileType::Directory,
            Self::File => FileType::RegularFile,
        }
    }

    fn perm(self) -> u16 {
        match self {
            Self::Directory => 0o555,
            Self::File => 0o444,
        }
    }
}

#[cfg(unix)]
fn current_uid() -> u32 {
    unsafe { libc::getuid() }
}

#[cfg(not(unix))]
fn current_uid() -> u32 {
    0
}

#[cfg(unix)]
fn current_gid() -> u32 {
    unsafe { libc::getgid() }
}

#[cfg(not(unix))]
fn current_gid() -> u32 {
    0
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{ProjectedEntry, ProjectedEntryKind};
    use std::collections::HashMap;

    #[test]
    fn tree_indexes_projection_for_lookup_and_readdir() {
        let projection = DriveProjection {
            workspace_id: "workspace-1".to_string(),
            entries: vec![
                directory("/Scope"),
                directory("/Scope/Channel"),
                directory("/Scope/Channel/Reports"),
                file("/Scope/Channel/Reports/summary.txt"),
            ],
            warnings: vec![],
        };

        let tree = ProjectionTree::from_projection(projection);
        let scope = tree.lookup(ROOT_INO, "Scope").unwrap();
        let channel = tree.lookup(scope.ino, "Channel").unwrap();
        let reports = tree.lookup(channel.ino, "Reports").unwrap();
        let file = tree.lookup(reports.ino, "summary.txt").unwrap();

        assert_eq!(scope.kind, NodeKind::Directory);
        assert_eq!(file.kind, NodeKind::File);
        assert_eq!(file.file_id.as_deref(), Some("file-1"));
        assert_eq!(tree.attr(file).perm, 0o444);
        assert_eq!(tree.attr(file).size, 14);

        let names = tree
            .directory_entries(reports.ino)
            .unwrap()
            .into_iter()
            .map(|entry| entry.name)
            .collect::<Vec<_>>();
        assert_eq!(names, vec![".", "..", "summary.txt"]);
    }

    #[test]
    fn tree_creates_missing_intermediate_directories() {
        let projection = DriveProjection {
            workspace_id: "workspace-1".to_string(),
            entries: vec![file("/Scope/Channel/note.txt")],
            warnings: vec![],
        };

        let tree = ProjectionTree::from_projection(projection);
        let scope = tree.lookup(ROOT_INO, "Scope").unwrap();
        let channel = tree.lookup(scope.ino, "Channel").unwrap();
        assert_eq!(channel.kind, NodeKind::Directory);
        assert_eq!(
            tree.lookup(channel.ino, "note.txt").unwrap().kind,
            NodeKind::File
        );
    }

    #[test]
    fn filesystem_reads_file_content_from_provider() {
        let projection = DriveProjection {
            workspace_id: "workspace-1".to_string(),
            entries: vec![file("/Scope/Channel/readme.txt")],
            warnings: vec![],
        };
        let fs = ProjectionFileSystem::new(
            projection,
            Arc::new(StaticFileReader::new([(
                "file-1",
                b"hello mounted drive".to_vec(),
            )])),
        );
        let scope = fs.tree.lookup(ROOT_INO, "Scope").unwrap();
        let channel = fs.tree.lookup(scope.ino, "Channel").unwrap();
        let file = fs.tree.lookup(channel.ino, "readme.txt").unwrap();
        let content = fs
            .file_reader
            .read_file(file.file_id.as_deref().unwrap())
            .unwrap();

        assert_eq!(content, b"hello mounted drive");
    }

    fn directory(path: &str) -> ProjectedEntry {
        ProjectedEntry {
            path: path.to_string(),
            kind: ProjectedEntryKind::Directory,
            item_id: None,
            file_id: None,
            local_state: None,
            storage_object_id: None,
            size_bytes: None,
        }
    }

    fn file(path: &str) -> ProjectedEntry {
        ProjectedEntry {
            path: path.to_string(),
            kind: ProjectedEntryKind::File,
            item_id: None,
            file_id: Some("file-1".to_string()),
            local_state: Some("online_only".to_string()),
            storage_object_id: None,
            size_bytes: Some(14),
        }
    }

    #[derive(Debug)]
    struct StaticFileReader {
        files: HashMap<String, Vec<u8>>,
    }

    impl StaticFileReader {
        fn new<const N: usize>(files: [(&str, Vec<u8>); N]) -> Self {
            Self {
                files: files
                    .into_iter()
                    .map(|(id, content)| (id.to_string(), content))
                    .collect(),
            }
        }
    }

    impl ProjectionFileReader for StaticFileReader {
        fn read_file(&self, file_id: &str) -> io::Result<Vec<u8>> {
            self.files.get(file_id).cloned().ok_or_else(|| {
                io::Error::new(io::ErrorKind::NotFound, format!("missing {file_id}"))
            })
        }
    }
}
