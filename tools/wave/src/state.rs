use crate::model::*;
use anyhow::{Context, Result, ensure};
use serde::{Serialize, de::DeserializeOwned};
use std::{
    ffi::CString,
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    os::unix::{
        fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
        io::AsRawFd,
    },
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

const LIMIT: u64 = 65536;
pub struct Paths {
    pub source: PathBuf,
    pub cli: PathBuf,
    pub native: PathBuf,
}
pub fn owner_uid() -> Result<u32> {
    let name = CString::new("kosciak")?;
    let entry = unsafe { libc::getpwnam(name.as_ptr()) };
    ensure!(!entry.is_null(), "Wave owner is unavailable");
    let uid = unsafe { (*entry).pw_uid };
    ensure!(uid != 0, "Wave owner must be unprivileged");
    Ok(uid)
}
pub fn directory(path: &Path, uid: u32, mode: u32) -> Result<()> {
    let meta = fs::symlink_metadata(path)?;
    ensure!(
        meta.is_dir() && meta.uid() == uid && meta.mode() & 0o7777 == mode,
        "unsafe Wave directory"
    );
    ensure!(path.canonicalize()? == path, "noncanonical Wave directory");
    Ok(())
}
impl Paths {
    pub fn installed() -> Result<Self> {
        let base = Path::new(BASE).canonicalize()?;
        let expected = if cfg!(target_os = "macos") {
            Path::new("/private/var/lib/wave-os")
        } else {
            Path::new(BASE)
        };
        ensure!(base == expected, "unexpected Wave base alias");
        for path in base.ancestors().take_while(|p| *p != Path::new("/")) {
            let meta = fs::symlink_metadata(path)?;
            ensure!(
                meta.is_dir() && meta.uid() == 0 && meta.mode() & 0o022 == 0,
                "unprotected Wave parent"
            );
        }
        let state = base.join("state");
        directory(&state, 0, 0o755)?;
        let paths = Self {
            source: base.join("source"),
            cli: state.join("cli"),
            native: state.join("native"),
        };
        directory(&paths.cli, owner_uid()?, 0o700)?;
        directory(&paths.native, 0, 0o755)?;
        match fs::symlink_metadata(&paths.source) {
            Ok(meta) => ensure!(
                meta.is_dir() && paths.source.canonicalize()? == paths.source,
                "unexpected source alias"
            ),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => (),
            Err(error) => return Err(error.into()),
        }
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
fn lock(path: &Path, uid: u32, mode: u32, create: bool, nonblocking: bool) -> Result<Lock> {
    let file = if create {
        match OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .mode(mode)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
            .open(path)
        {
            Ok(file) => {
                file.set_permissions(fs::Permissions::from_mode(mode))?;
                file.sync_all()?;
                file
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => OpenOptions::new()
                .read(true)
                .write(true)
                .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
                .open(path)?,
            Err(error) => return Err(error.into()),
        }
    } else {
        OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
            .open(path)?
    };
    regular(&file, uid, mode)?;
    let flags = libc::LOCK_EX | if nonblocking { libc::LOCK_NB } else { 0 };
    ensure!(
        unsafe { libc::flock(file.as_raw_fd(), flags) } == 0,
        "Wave lock is busy or unavailable"
    );
    Ok(Lock(file))
}
pub fn operation_lock(paths: &Paths, create: bool) -> Result<Lock> {
    directory(&paths.cli, owner_uid()?, 0o700)?;
    ensure!(
        unsafe { libc::geteuid() } == owner_uid()?,
        "operation lock requires Wave owner"
    );
    lock(
        &paths.cli.join("operation.lock"),
        owner_uid()?,
        0o600,
        create,
        true,
    )
}
pub fn root_lock(paths: &Paths) -> Result<Lock> {
    ensure!(unsafe { libc::geteuid() } == 0, "native lock requires root");
    directory(&paths.native, 0, 0o755)?;
    lock(&paths.native.join("native.lock"), 0, 0o644, true, false)
}
pub fn record_lock(paths: &Paths, create: bool) -> Result<Lock> {
    ensure!(
        unsafe { libc::geteuid() } == owner_uid()?,
        "record lock requires Wave owner"
    );
    directory(&paths.cli, owner_uid()?, 0o700)?;
    lock(
        &paths.cli.join("record.lock"),
        owner_uid()?,
        0o600,
        create,
        false,
    )
}
fn regular(file: &File, uid: u32, mode: u32) -> Result<()> {
    let meta = file.metadata()?;
    ensure!(
        meta.is_file()
            && meta.uid() == uid
            && meta.mode() & 0o7777 == mode
            && meta.nlink() == 1
            && meta.len() <= LIMIT,
        "unsafe Wave record"
    );
    Ok(())
}
fn read_json<T: DeserializeOwned>(path: &Path, uid: u32, mode: u32) -> Result<Option<T>> {
    let file = match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path)
    {
        Ok(file) => file,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e.into()),
    };
    regular(&file, uid, mode)?;
    let mut bytes = Vec::new();
    file.take(LIMIT + 1).read_to_end(&mut bytes)?;
    ensure!(bytes.len() <= LIMIT as usize, "oversized Wave record");
    Ok(Some(
        serde_json::from_slice(&bytes).context("invalid Wave record")?,
    ))
}
fn atomic<T: Serialize>(parent: &Path, name: &str, value: &T, mode: u32) -> Result<()> {
    let mut file = tempfile::NamedTempFile::new_in(parent)?;
    file.as_file()
        .set_permissions(fs::Permissions::from_mode(mode))?;
    serde_json::to_writer(&mut file, value)?;
    file.flush()?;
    file.as_file().sync_all()?;
    file.persist(parent.join(name)).map_err(|e| e.error)?;
    File::open(parent)?.sync_all()?;
    Ok(())
}
pub fn load(paths: &Paths) -> Result<State> {
    directory(&paths.cli, owner_uid()?, 0o700)?;
    let value = read_json::<State>(&paths.cli.join("state.json"), owner_uid()?, 0o600)?;
    let state = match value {
        Some(value) => value,
        None => {
            ensure!(
                receipt(paths)?.is_none(),
                "user state missing with native evidence"
            );
            State::default()
        }
    };
    validate_state(&state)?;
    Ok(state)
}
pub fn update<T>(paths: &Paths, f: impl FnOnce(&mut State) -> Result<T>) -> Result<T> {
    ensure!(
        unsafe { libc::geteuid() } == owner_uid()?,
        "state update requires Wave owner"
    );
    directory(&paths.cli, owner_uid()?, 0o700)?;
    let _lock = record_lock(paths, true)?;
    let mut state = load(paths)?;
    let result = f(&mut state)?;
    validate_state(&state)?;
    atomic(&paths.cli, "state.json", &state, 0o600)?;
    Ok(result)
}
pub fn receipt(paths: &Paths) -> Result<Option<NativeReceipt>> {
    directory(&paths.native, 0, 0o755)?;
    let receipt = read_json::<NativeReceipt>(&paths.native.join("receipt.json"), 0, 0o644)?;
    if let Some(value) = &receipt {
        validate_receipt(value)?;
    }
    Ok(receipt)
}
pub fn write_receipt(paths: &Paths, value: &NativeReceipt) -> Result<()> {
    ensure!(
        unsafe { libc::geteuid() } == 0,
        "receipt update requires root"
    );
    directory(&paths.native, 0, 0o755)?;
    validate_receipt(value)?;
    atomic(&paths.native, "receipt.json", value, 0o644)
}
pub fn lexical_store_path(path: &Path) -> bool {
    let Some(name) = path.file_name().and_then(|s| s.to_str()) else {
        return false;
    };
    let bytes = name.as_bytes();
    path.parent() == Some(Path::new("/nix/store"))
        && path.as_os_str() == Path::new("/nix/store").join(name).as_os_str()
        && bytes.len() > 33
        && bytes.len() <= 255
        && bytes[32] == b'-'
        && bytes[..32]
            .iter()
            .all(|b| b"0123456789abcdfghijklmnpqrsvwxyz".contains(b))
        && bytes[33..]
            .iter()
            .all(|b| b.is_ascii_alphanumeric() || b"+-._?=".contains(b))
}
pub fn valid_store_path(path: &Path) -> bool {
    lexical_store_path(path)
        && path.canonicalize().is_ok_and(|p| p == path)
        && fs::metadata(path).is_ok_and(|m| m.is_dir() && m.uid() == 0 && m.mode() & 0o022 == 0)
}
fn immutable_store_node(path: &Path) -> bool {
    lexical_store_path(path)
        && path.canonicalize().is_ok_and(|resolved| resolved == path)
        && fs::metadata(path).is_ok_and(|meta| {
            (meta.is_dir() || meta.is_file()) && meta.uid() == 0 && meta.mode() & 0o022 == 0
        })
}
fn validate_snapshot_record(value: &Snapshot) -> Result<()> {
    ensure!(
        lexical_store_path(&value.profile) && lexical_store_path(&value.system),
        "invalid recorded store snapshot"
    );
    Ok(())
}
pub fn validate_snapshot(value: &Snapshot) -> Result<()> {
    ensure!(
        valid_store_path(&value.profile) && valid_store_path(&value.system),
        "invalid store snapshot"
    );
    if value.profile != value.system {
        ensure!(
            Path::new(store_text(&value.profile.join("systemConfig"), 4096)?.trim())
                == value.system,
            "incoherent wrapped profile"
        );
    }
    Ok(())
}
fn store_text(path: &Path, limit: u64) -> Result<String> {
    let resolved = path.canonicalize()?;
    let root = resolved
        .ancestors()
        .find(|p| p.parent() == Some(Path::new("/nix/store")))
        .context("marker outside store")?;
    ensure!(immutable_store_node(root), "unsafe store marker closure");
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(&resolved)?;
    let meta = file.metadata()?;
    ensure!(
        meta.is_file() && meta.uid() == 0 && meta.mode() & 0o022 == 0 && meta.len() <= limit,
        "unsafe store text"
    );
    let mut bytes = Vec::new();
    file.take(limit + 1).read_to_end(&mut bytes)?;
    ensure!(bytes.len() <= limit as usize, "oversized store text");
    Ok(String::from_utf8(bytes)?)
}
pub fn store_executable(path: &Path) -> Result<()> {
    ensure!(
        path.is_absolute() && path.as_os_str().len() <= 4096,
        "invalid store executable"
    );
    let root = path
        .ancestors()
        .find(|p| p.parent() == Some(Path::new("/nix/store")))
        .context("executable outside store")?;
    ensure!(
        immutable_store_node(root) && path.canonicalize()? == path,
        "noncanonical store executable"
    );
    let meta = fs::symlink_metadata(path)?;
    ensure!(
        meta.is_file() && meta.uid() == 0 && meta.mode() & 0o022 == 0 && meta.mode() & 0o111 != 0,
        "unsafe store executable"
    );
    Ok(())
}
pub fn activator(profile: &Path) -> Result<PathBuf> {
    ensure!(valid_store_path(profile), "invalid activator profile");
    let script = profile.join("activate-rs").canonicalize()?;
    store_executable(&script)?;
    let text = store_text(&script, 4096)?;
    let lines: Vec<_> = text.lines().collect();
    ensure!(
        lines.len() == 2 && text.ends_with('\n'),
        "unexpected activate-rs script"
    );
    let shell = lines[0]
        .strip_prefix("#!")
        .context("missing activator interpreter")?;
    store_executable(Path::new(shell))?;
    let target = lines[1]
        .strip_prefix("exec ")
        .and_then(|line| line.strip_suffix(" \"$@\""))
        .context("unexpected activator exec line")?;
    let target = PathBuf::from(target);
    ensure!(
        target.ends_with("bin/activate"),
        "unexpected native activator"
    );
    store_executable(&target)?;
    Ok(target)
}
pub fn snapshot() -> Result<Snapshot> {
    let value = Snapshot {
        profile: Path::new(PROFILE).canonicalize()?,
        system: Path::new(CURRENT).canonicalize()?,
    };
    validate_snapshot(&value)?;
    Ok(value)
}
pub fn validate_operation(value: &Operation) -> Result<()> {
    ensure!(
        !value.id.is_empty()
            && value.id.len() <= 80
            && value
                .id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-'),
        "invalid operation identity"
    );
    ensure!(sha40(&value.commit), "invalid operation commit");
    validate_snapshot_record(&value.old)?;
    validate_snapshot_record(&value.new)?;
    let base = if cfg!(target_os = "macos") {
        "/private/var/lib/wave-os/state/native"
    } else {
        "/var/lib/wave-os/state/native"
    };
    ensure!(
        value.temp == Path::new(base).join(&value.id),
        "invalid native temporary directory"
    );
    Ok(())
}
pub fn same_operation(a: &Operation, b: &Operation) -> bool {
    a.id == b.id
        && a.host == b.host
        && a.commit == b.commit
        && a.old == b.old
        && a.new == b.new
        && a.temp == b.temp
}
fn validate_state(value: &State) -> Result<()> {
    if let Some(op) = &value.operation {
        validate_operation(op)?;
    }
    if let Some(result) = &value.last_result {
        ensure!(
            !result.id.is_empty()
                && result.id.len() <= 80
                && result
                    .id
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'-')
                && sha40(&result.commit),
            "invalid result identity"
        );
        validate_snapshot_record(&result.snapshot)?;
    }
    if let Some(commit) = &value.rollback_commit {
        ensure!(sha40(commit), "invalid rollback commit");
    }
    Ok(())
}
pub fn validate_receipt(value: &NativeReceipt) -> Result<()> {
    validate_operation(&value.operation)?;
    ensure!(
        value.supervisor_pid > 1 && (value.child_pid == 0 || value.child_pid > 1),
        "invalid native process identity"
    );
    ensure!(
        value.terminal || (value.exit_code.is_none() && value.snapshot.is_none()),
        "invalid running receipt"
    );
    ensure!(
        value.exit_code.is_none() || value.child_pid > 1,
        "exit without child"
    );
    ensure!(
        value.child_pid != 0 || !value.confirmed,
        "confirmation without child"
    );
    if value.terminal && value.child_pid == 0 {
        ensure!(
            prelaunch_failed(value),
            "invalid terminal no-child attestation"
        );
    }
    if let Some(snapshot) = &value.snapshot {
        validate_snapshot_record(snapshot)?;
    }
    Ok(())
}
pub fn prelaunch_failed(value: &NativeReceipt) -> bool {
    value.terminal
        && value.child_pid == 0
        && value.exit_code.is_none()
        && !value.confirmed
        && value.snapshot.as_ref() == Some(&value.operation.old)
}
pub fn canary(op: &Operation) -> Result<PathBuf> {
    validate_operation(op)?;
    let name = op
        .new
        .profile
        .file_name()
        .and_then(|s| s.to_str())
        .context("invalid profile name")?;
    Ok(op.temp.join(format!("deploy-rs-canary-{}", &name[..32])))
}
pub fn process_command(pid: u32) -> Result<Option<String>> {
    Ok(process_identity(pid)?.map(|(_, command)| command))
}
fn operation_bound(command: &str, op: &Operation) -> bool {
    command.contains(op.temp.to_string_lossy().as_ref())
        && command.split_whitespace().any(|s| {
            s.contains("wave")
                || s.contains("deploy")
                || s.ends_with("/ssh")
                || s == "ssh"
                || s.contains("activate-rs")
                || s.ends_with("/bin/activate")
        })
}
pub fn quiescent(value: &NativeReceipt) -> Result<()> {
    validate_receipt(value)?;
    ensure!(
        prelaunch_failed(value)
            || (value.terminal
                && value.exit_code.is_some()
                && value.child_pid > 1
                && value.snapshot.is_some()),
        "native outcome is running or unknown"
    );
    for pid in [value.supervisor_pid, value.child_pid] {
        if pid == 0 || pid == std::process::id() {
            continue;
        }
        if let Some(command) = process_command(pid)? {
            ensure!(
                !operation_bound(&command, &value.operation),
                "operation-bound native process still present"
            );
        }
    }
    no_processes(&value.operation, Some(value.supervisor_pid))
}
pub fn no_operation_processes(op: &Operation) -> Result<()> {
    validate_operation(op)?;
    no_processes(op, None)
}
fn no_processes(op: &Operation, supervisor: Option<u32>) -> Result<()> {
    let output = crate::process::capture_uncancelled(
        Command::new(ps())
            .args(["-axww", "-o", "pid=", "-o", "ppid=", "-o", "command="])
            .stdin(Stdio::null())
            .stderr(Stdio::null()),
        std::time::Duration::from_secs(2),
    )?;
    ensure!(
        output.code == 0
            && !output.interrupted
            && !output.timed_out
            && output.stdout.len() <= 4 * 1024 * 1024,
        "cannot exclude orphan processes"
    );
    let text = String::from_utf8(output.stdout)?;
    let mut processes = Vec::new();
    for line in text.lines() {
        let (pid, rest) = line
            .trim()
            .split_once(char::is_whitespace)
            .context("invalid process listing")?;
        let (parent, command) = rest
            .trim_start()
            .split_once(char::is_whitespace)
            .context("invalid process listing")?;
        processes.push((
            pid.parse::<u32>().context("invalid process listing PID")?,
            parent
                .parse::<u32>()
                .context("invalid process parent PID")?,
            command,
        ));
    }
    let mut excluded = vec![std::process::id()];
    // The supervisor cleans after reaping; its own sudo/SSH ancestors are not orphans.
    if supervisor == Some(std::process::id()) && unsafe { libc::geteuid() } == 0 {
        let mut pid = std::process::id();
        while let Some((_, parent, _)) =
            processes.iter().find(|(candidate, _, _)| *candidate == pid)
        {
            if *parent <= 1 || excluded.contains(parent) {
                break;
            }
            excluded.push(*parent);
            pid = *parent;
        }
    }
    for (pid, _, command) in processes {
        if excluded.contains(&pid) {
            continue;
        }
        ensure!(
            !operation_bound(command, op),
            "operation-bound orphan process exists"
        );
    }
    Ok(())
}
fn process_identity(pid: u32) -> Result<Option<(u32, String)>> {
    ensure!(pid > 1, "invalid process PID");
    let output = crate::process::capture_uncancelled(
        Command::new(ps())
            .args([
                "-ww",
                "-p",
                &pid.to_string(),
                "-o",
                "uid=",
                "-o",
                "stat=",
                "-o",
                "command=",
            ])
            .stdin(Stdio::null())
            .stderr(Stdio::null()),
        std::time::Duration::from_secs(2),
    )?;
    ensure!(
        !output.interrupted && !output.timed_out,
        "process identity unavailable"
    );
    ensure!(
        output.stdout.len() <= LIMIT as usize,
        "oversized process identity"
    );
    if output.code == 1 && output.stdout.is_empty() {
        return Ok(None);
    }
    ensure!(output.code == 0, "process identity unavailable");
    let text = String::from_utf8(output.stdout)?;
    let text = text.trim();
    let (uid, rest) = text
        .split_once(char::is_whitespace)
        .context("invalid process identity")?;
    let uid = uid.parse::<u32>().context("invalid process owner")?;
    let (status, command) = rest
        .trim_start()
        .split_once(char::is_whitespace)
        .context("invalid process identity")?;
    if status.contains('Z') {
        return Ok(None);
    }
    ensure!(!command.trim().is_empty(), "empty process identity");
    Ok(Some((uid, command.trim().to_owned())))
}
fn ps() -> &'static str {
    if cfg!(target_os = "macos") {
        "/bin/ps"
    } else {
        "ps"
    }
}
pub fn native_alive(value: &NativeReceipt) -> Result<bool> {
    validate_receipt(value)?;
    if value.terminal || value.child_pid == 0 {
        return Ok(false);
    }
    let Some((supervisor_uid, supervisor)) = process_identity(value.supervisor_pid)? else {
        return Ok(false);
    };
    let supervisor: Vec<&str> = supervisor.split_whitespace().collect();
    let original_executable = value
        .operation
        .new
        .profile
        .join("activate-rs")
        .display()
        .to_string();
    let expected = activation_arguments(&value.operation);
    let suffix = std::iter::once(original_executable.as_str())
        .chain(expected.iter().map(String::as_str))
        .collect::<Vec<_>>();
    if supervisor_uid != 0 || !supervisor.contains(&"__native") || !supervisor.ends_with(&suffix) {
        return Ok(false);
    }
    let Some((child_uid, command)) = process_identity(value.child_pid)? else {
        return Ok(false);
    };
    let fields: Vec<&str> = command.split_whitespace().collect();
    let executable = activator(&value.operation.new.profile)?;
    Ok(child_uid == 0
        && fields
            .first()
            .is_some_and(|v| *v == executable.to_string_lossy())
        && fields[1..] == expected.iter().map(String::as_str).collect::<Vec<_>>())
}
pub fn activation_arguments(op: &Operation) -> Vec<String> {
    vec![
        "activate".into(),
        op.new.profile.display().to_string(),
        "--profile-path".into(),
        PROFILE.into(),
        "--temp-path".into(),
        op.temp.display().to_string(),
        "--confirm-timeout".into(),
        CONFIRM_TIMEOUT.to_string(),
        "--magic-rollback".into(),
        "--auto-rollback".into(),
    ]
}
