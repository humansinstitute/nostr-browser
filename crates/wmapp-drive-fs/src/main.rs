//! Bounded, read-only filesystem port. Every component is opened relative to an
//! already-pinned directory descriptor with O_NOFOLLOW. Never canonicalize then open.
use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::{json, Value};
use std::{
    ffi::{CStr, CString},
    fs::File,
    io::{Read, Seek, SeekFrom, Write},
    os::fd::{AsRawFd, FromRawFd},
    os::unix::fs::MetadataExt,
};
fn open_at(parent: i32, name: &str, directory: bool) -> Result<File, String> {
    let c = CString::new(name).map_err(|_| "invalid_path")?;
    let fd = unsafe {
        libc::openat(
            parent,
            c.as_ptr(),
            libc::O_RDONLY
                | libc::O_NOFOLLOW
                | libc::O_CLOEXEC
                | libc::O_NONBLOCK
                | if directory { libc::O_DIRECTORY } else { 0 },
        )
    };
    if fd < 0 {
        return Err("missing_or_unsafe_path".into());
    }
    Ok(unsafe { File::from_raw_fd(fd) })
}
fn components(path: &str) -> Result<Vec<&str>, String> {
    if path.len() > 4096 || path.contains('\\') || path.contains('\0') {
        return Err("invalid_path".into());
    }
    if path.is_empty() {
        return Ok(vec![]);
    }
    let parts: Vec<_> = path.split('/').collect();
    if parts
        .iter()
        .any(|s| s.is_empty() || *s == "." || *s == "..")
    {
        return Err("invalid_path".into());
    }
    Ok(parts)
}
fn open_root(root: &str) -> Result<File, String> {
    if !root.starts_with('/') || root == "/" {
        return Err("invalid_root".into());
    }
    let mut fd = open_at(libc::AT_FDCWD, "/", true)?;
    for part in components(&root[1..])? {
        fd = open_at(fd.as_raw_fd(), part, true)?
    }
    Ok(fd)
}
fn resolve(root: &str, path: &str, directory: bool) -> Result<File, String> {
    let mut fd = open_root(root)?;
    let parts = components(path)?;
    for (i, part) in parts.iter().enumerate() {
        fd = open_at(fd.as_raw_fd(), part, i + 1 < parts.len() || directory)?
    }
    Ok(fd)
}
fn revision(m: &std::fs::Metadata) -> String {
    format!(
        "{}-{}-{}-{}-{}-{}-{}",
        m.dev(),
        m.ino(),
        m.len(),
        m.mtime(),
        m.mtime_nsec(),
        m.ctime(),
        m.ctime_nsec()
    )
}
fn run(v: Value) -> Result<Value, String> {
    let root = v["root"].as_str().ok_or("invalid_root")?;
    let path = v["path"].as_str().ok_or("invalid_path")?;
    match v["operation"].as_str() {
        Some("list") => {
            let dir = resolve(root, path, true)?;
            let meta = dir.metadata().map_err(|_| "missing")?;
            let rev = revision(&meta);
            let duplicate = unsafe { libc::dup(dir.as_raw_fd()) };
            if duplicate < 0 {
                return Err("unavailable".into());
            }
            let stream = unsafe { libc::fdopendir(duplicate) };
            if stream.is_null() {
                unsafe { libc::close(duplicate) };
                return Err("unavailable".into());
            }
            let mut entries = vec![];
            let mut count = 0;
            loop {
                let ent = unsafe { libc::readdir(stream) };
                if ent.is_null() {
                    break;
                }
                let name = unsafe { CStr::from_ptr((*ent).d_name.as_ptr()) }
                    .to_string_lossy()
                    .into_owned();
                if name == "." || name == ".." {
                    continue;
                }
                count += 1;
                if count > 10000 {
                    unsafe { libc::closedir(stream) };
                    return Err("directory_too_large".into());
                }
                // Symlinks, pipes, sockets, devices and unreadable entries are not exposed.
                if let Ok(file) = open_at(dir.as_raw_fd(), &name, false) {
                    if let Ok(m) = file.metadata() {
                        if m.is_file() || m.is_dir() {
                            entries.push(json!({"name":name,"kind":if m.is_dir(){"directory"}else{"file"},"size":m.len(),"revision":revision(&m)}));
                        }
                    }
                }
            }
            unsafe { libc::closedir(stream) };
            if revision(&dir.metadata().map_err(|_| "missing")?) != rev {
                return Err("changed".into());
            }
            entries.sort_by(|a, b| a["name"].as_str().cmp(&b["name"].as_str()));
            let offset = v["offset"].as_u64().unwrap_or(0) as usize;
            let limit = 100;
            if offset > 0 && v["revision"].as_str() != Some(&rev) {
                return Err("changed".into());
            }
            let next = if offset + limit < entries.len() {
                Some(offset + limit)
            } else {
                None
            };
            Ok(
                json!({"entries":entries.into_iter().skip(offset).take(limit).collect::<Vec<_>>(),"revision":rev,"next_offset":next}),
            )
        }
        Some("read") => {
            let mut file = resolve(root, path, false)?;
            let m = file.metadata().map_err(|_| "missing")?;
            if !m.is_file() {
                return Err("not_file".into());
            }
            let rev = revision(&m);
            if v["revision"].as_str() != Some(&rev) {
                return Err("changed".into());
            }
            let offset = v["offset"].as_u64().ok_or("invalid_offset")?;
            if offset > m.len() {
                return Err("changed".into());
            }
            file.seek(SeekFrom::Start(offset)).map_err(|_| "missing")?;
            let mut bytes = vec![0; 65536.min((m.len() - offset) as usize)];
            file.read_exact(&mut bytes).map_err(|_| "changed")?;
            if revision(&file.metadata().map_err(|_| "missing")?) != rev {
                return Err("changed".into());
            }
            Ok(
                json!({"chunk":STANDARD.encode(&bytes),"size":m.len(),"done":offset+bytes.len() as u64==m.len(),"revision":rev}),
            )
        }
        _ => Err("unsupported_operation".into()),
    }
}
fn main() {
    let mut raw = String::new();
    let result = std::io::stdin()
        .take(16385)
        .read_to_string(&mut raw)
        .map_err(|_| "invalid_request".into())
        .and_then(|_| {
            if raw.len() > 16384 {
                return Err("request_too_large".into());
            }
            let v = serde_json::from_str(&raw).map_err(|_| "invalid_request")?;
            run(v)
        });
    let out = match result {
        Ok(v) => v,
        Err(code) => json!({"error":code}),
    };
    writeln!(std::io::stdout(), "{}", out).ok();
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;
    #[test]
    fn confinement_and_changes() {
        let root = std::env::temp_dir().join(format!("drive-fs-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let root = root.canonicalize().unwrap();
        std::fs::write(root.join("file"), vec![42; 200000]).unwrap();
        symlink("/etc", root.join("escape")).unwrap();
        let r = root.to_str().unwrap();
        let listing = run(json!({"operation":"list","root":r,"path":""})).unwrap();
        assert_eq!(listing["entries"].as_array().unwrap().len(), 1);
        for path in ["../etc/passwd", "escape/passwd", "/etc/passwd", "a//b"] {
            assert!(
                run(json!({"operation":"read","root":r,"path":path,"revision":"x","offset":0}))
                    .is_err()
            )
        }
        let rev = &listing["entries"][0]["revision"];
        let chunk =
            run(json!({"operation":"read","root":r,"path":"file","revision":rev,"offset":0}))
                .unwrap();
        assert_eq!(
            STANDARD
                .decode(chunk["chunk"].as_str().unwrap())
                .unwrap()
                .len(),
            65536
        );
        std::fs::write(root.join("file"), b"changed").unwrap();
        assert_eq!(
            run(json!({"operation":"read","root":r,"path":"file","revision":rev,"offset":0}))
                .unwrap_err(),
            "changed"
        );
        std::fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn pinned_directory_survives_symlink_swap() {
        let root = std::env::temp_dir().join(format!("drive-race-{}", std::process::id()));
        std::fs::create_dir_all(root.join("child")).unwrap();
        std::fs::write(root.join("child/safe"), "safe").unwrap();
        let root = root.canonicalize().unwrap();
        let fd = resolve(root.to_str().unwrap(), "child", true).unwrap();
        std::fs::rename(root.join("child"), root.join("moved")).unwrap();
        symlink("/etc", root.join("child")).unwrap();
        assert!(open_at(fd.as_raw_fd(), "passwd", false).is_err());
        assert!(open_at(fd.as_raw_fd(), "safe", false).is_ok());
        assert!(resolve(root.to_str().unwrap(), "child/passwd", false).is_err());
        std::fs::remove_dir_all(root).unwrap();
    }
}
