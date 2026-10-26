use crate::model::BASE;
use anyhow::{Context, Result, ensure};
use std::{
    ffi::CString,
    fs::{self, File, OpenOptions},
    os::unix::{
        fs::{MetadataExt, OpenOptionsExt},
        io::AsRawFd,
    },
    path::{Path, PathBuf},
};

pub struct Paths {
    pub source: PathBuf,
    pub cli: PathBuf,
}

pub fn owner_uid() -> Result<u32> {
    let name = CString::new("kosciak")?;
    let entry = unsafe { libc::getpwnam(name.as_ptr()) };
    ensure!(!entry.is_null(), "wave-os owner is unavailable");
    Ok(unsafe { (*entry).pw_uid })
}

pub fn directory(path: &Path, uid: u32, mode: u32) -> Result<()> {
    let meta =
        fs::symlink_metadata(path).with_context(|| format!("{} is missing", path.display()))?;
    ensure!(
        meta.is_dir() && meta.uid() == uid && meta.mode() & 0o7777 == mode,
        "{} must be a directory owned by uid {uid} with mode {mode:o}",
        path.display()
    );
    Ok(())
}

impl Paths {
    pub fn installed() -> Result<Self> {
        let base = Path::new(BASE).canonicalize()?;
        let paths = Self {
            source: base.join("source"),
            cli: base.join("state/cli"),
        };
        let owner = owner_uid()?;
        directory(&paths.source, owner, 0o700)?;
        directory(&paths.cli, owner, 0o700)?;
        Ok(paths)
    }
}

pub struct Lock(File);

impl Drop for Lock {
    fn drop(&mut self) {
        unsafe {
            libc::flock(self.0.as_raw_fd(), libc::LOCK_UN);
        }
    }
}

/// One wave-os operation at a time per host.
pub fn operation_lock(paths: &Paths) -> Result<Lock> {
    try_operation_lock(paths)?.context("another wave-os operation is running")
}

pub fn try_operation_lock(paths: &Paths) -> Result<Option<Lock>> {
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(paths.cli.join("operation.lock"))?;
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
        return Ok(Some(Lock(file)));
    }
    let error = std::io::Error::last_os_error();
    if error.kind() == std::io::ErrorKind::WouldBlock {
        Ok(None)
    } else {
        Err(error.into())
    }
}

pub fn valid_store_path(path: &Path) -> bool {
    path.parent() == Some(Path::new("/nix/store"))
        && path.canonicalize().is_ok_and(|resolved| resolved == path)
}
