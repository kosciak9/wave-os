use crate::{
    health, logging,
    model::*,
    process,
    state::{self, Paths},
};
use anyhow::{Context, Result, bail, ensure};
use clap::Args;
use std::{
    fs::{self, File},
    os::unix::{
        fs::{MetadataExt, PermissionsExt},
        process::CommandExt,
    },
    path::{Path, PathBuf},
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant, SystemTime},
};

#[derive(Args, Debug)]
pub struct NativeArgs {
    #[arg(long)]
    pub host: Host,
    #[arg(long)]
    pub profile: PathBuf,
    #[arg(long)]
    pub system: PathBuf,
    #[arg(long)]
    pub owner: String,
    #[arg(last = true)]
    pub args: Vec<String>,
}
#[derive(Args, Debug)]
pub struct ConfirmArgs {
    #[arg(long)]
    pub host: Host,
    #[arg(long)]
    pub profile: PathBuf,
    #[arg(long)]
    pub system: PathBuf,
    #[arg(long)]
    pub owner: String,
    #[arg(long)]
    pub root_wrapper: PathBuf,
    pub canary: PathBuf,
}
fn identity(host: Host, profile: &Path, system: &Path, owner: &str) -> Result<()> {
    ensure!(owner == "kosciak", "unexpected helper owner");
    ensure!(
        if cfg!(all(target_os = "macos", target_arch = "aarch64")) {
            host == Host::Renekton
        } else if cfg!(all(target_os = "linux", target_arch = "x86_64")) {
            host == Host::Jayce
        } else if cfg!(all(target_os = "linux", target_arch = "aarch64")) {
            host == Host::Ahri
        } else {
            false
        },
        "helper platform mismatch"
    );
    state::validate_snapshot(&Snapshot {
        profile: profile.into(),
        system: system.into(),
    })
}
fn bound(op: &Operation, host: Host, profile: &Path, system: &Path) -> Result<()> {
    state::validate_operation(op)?;
    ensure!(
        op.host == host && op.new.profile == profile && op.new.system == system,
        "helper operation identity mismatch"
    );
    Ok(())
}
// Root never opens owner-controlled records with root's filesystem authority.
fn owner_state(paths: &Paths) -> Result<State> {
    if unsafe { libc::geteuid() } != 0 {
        return state::load(paths);
    }
    let uid = state::owner_uid()?;
    ensure!(
        unsafe { libc::seteuid(uid) } == 0,
        "cannot read records as owner"
    );
    let result = state::load(paths);
    if unsafe { libc::seteuid(0) } != 0 {
        std::process::abort();
    }
    result
}
fn owner_record_lock(paths: &Paths) -> Result<state::Lock> {
    ensure!(
        unsafe { libc::seteuid(state::owner_uid()?) } == 0,
        "cannot lock records as owner"
    );
    let result = state::record_lock(paths, false);
    if unsafe { libc::seteuid(0) } != 0 {
        std::process::abort();
    }
    result
}
fn wait_arguments(op: &Operation) -> Vec<String> {
    vec![
        "wait".into(),
        op.new.profile.display().to_string(),
        "--temp-path".into(),
        op.temp.display().to_string(),
        "--activation-timeout".into(),
        ACTIVATION_TIMEOUT.to_string(),
    ]
}
fn store_executable(path: &Path) -> Result<()> {
    state::store_executable(path)
}
fn command(op: &Operation, arguments: &[String]) -> Result<Command> {
    let executable = state::activator(&op.new.profile)?;
    let mut command = Command::new(executable);
    command
        .args(arguments)
        .env_clear()
        .env(
            "PATH",
            "/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin:/usr/bin:/bin",
        )
        .env(
            "HOME",
            if cfg!(target_os = "macos") {
                "/var/root"
            } else {
                "/root"
            },
        )
        .current_dir("/")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    Ok(command)
}
fn ensure_temp(paths: &Paths, op: &Operation) -> Result<()> {
    ensure!(
        op.temp.parent() == Some(paths.native.as_path()),
        "temporary directory outside native state"
    );
    match fs::create_dir(&op.temp) {
        Ok(()) => {
            fs::set_permissions(&op.temp, fs::Permissions::from_mode(0o755))?;
            File::open(&paths.native)?.sync_all()?;
        }
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => (),
        Err(error) => return Err(error.into()),
    }
    state::directory(&op.temp, 0, 0o755)
}
fn validate_resolved(paths: &Paths, receipt: &NativeReceipt) -> Result<()> {
    let op = &receipt.operation;
    let reconciled = owner_state(paths)?.last_result.is_some_and(|result| {
        result.id == op.id
            && result.commit == op.commit
            && result.outcome == Outcome::Reconciled
            && state::snapshot().is_ok_and(|snapshot| result.snapshot == snapshot)
    });
    ensure!(
        state::prelaunch_failed(receipt)
            || (receipt.exit_code == Some(0)
                && receipt.confirmed
                && receipt.snapshot.as_ref() == Some(&op.new))
            || (receipt.exit_code.is_some_and(|code| code != 0)
                && receipt.snapshot.as_ref() == Some(&op.old))
            || reconciled,
        "unresolved native outcome"
    );
    Ok(())
}
fn cleanup_temp(paths: &Paths, receipt: &NativeReceipt) -> Result<()> {
    let op = &receipt.operation;
    validate_resolved(paths, receipt)?;
    state::quiescent(receipt)?;
    ensure!(
        op.temp.parent() == Some(paths.native.as_path()),
        "temporary directory outside native state"
    );
    match fs::symlink_metadata(&op.temp) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error.into()),
        Ok(_) => state::directory(&op.temp, 0, 0o755)?,
    }
    let canary = state::canary(op)?;
    let cancel = op.temp.join(
        canary
            .file_name()
            .context("missing canary name")?
            .to_string_lossy()
            .replace("deploy-rs-canary-", "deploy-rs-cancel-"),
    );
    let mut files = Vec::new();
    for entry in fs::read_dir(&op.temp)? {
        let path = entry?.path();
        ensure!(
            path == canary || path == cancel,
            "unexpected native temporary file"
        );
        let meta = fs::symlink_metadata(&path)?;
        ensure!(
            meta.is_file()
                && meta.uid() == 0
                && meta.mode() & 0o022 == 0
                && meta.nlink() == 1
                && meta.len() == 0,
            "unsafe native temporary file"
        );
        files.push(path);
    }
    for path in files {
        fs::remove_file(path)?;
    }
    File::open(&op.temp)?.sync_all()?;
    fs::remove_dir(&op.temp)?;
    File::open(&paths.native)?.sync_all()?;
    Ok(())
}
fn canary_valid(op: &Operation, path: &Path) -> Result<()> {
    ensure!(state::canary(op)? == path, "canary identity mismatch");
    state::directory(&op.temp, 0, 0o755)?;
    ensure!(path.canonicalize()? == path, "noncanonical canary");
    let meta = fs::symlink_metadata(path)?;
    ensure!(
        meta.is_file()
            && meta.uid() == 0
            && meta.mode() & 0o022 == 0
            && meta.nlink() == 1
            // Pinned activate.rs uses File::create and never writes the sentinel.
            && meta.len() == 0,
        "unsafe canary"
    );
    let age = SystemTime::now()
        .duration_since(meta.modified()?)
        .context("canary from future")?;
    ensure!(
        age < Duration::from_secs(CONFIRM_TIMEOUT - 10),
        "confirmation deadline elapsed"
    );
    Ok(())
}
fn eligible(paths: &Paths, op: &Operation, path: &Path) -> Result<NativeReceipt> {
    ensure!(!process::cancelled(), "confirmation interrupted");
    let current = owner_state(paths)?.operation.context("operation missing")?;
    ensure!(
        state::same_operation(op, &current) && !current.cancelled,
        "operation changed or cancelled"
    );
    canary_valid(&current, path)?;
    ensure!(state::snapshot()? == op.new, "active system changed");
    let receipt = state::receipt(paths)?.context("native receipt missing")?;
    ensure!(
        state::same_operation(op, &receipt.operation)
            && !receipt.confirmed
            && state::native_alive(&receipt)?,
        "native identity unavailable"
    );
    Ok(receipt)
}
fn remove_canary(paths: &Paths, op: &Operation, path: &Path) -> Result<i32> {
    let _lock = state::root_lock(paths)?;
    let _record_lock = owner_record_lock(paths)?;
    let mut receipt = eligible(paths, op, path)?;
    let current = owner_state(paths)?.operation.context("operation missing")?;
    ensure!(
        current.health_approved && !current.cancelled && state::same_operation(op, &current),
        "health approval missing"
    );
    // Durable root proof precedes the deletion event consumed by deploy-rs.
    receipt.confirmed = true;
    state::write_receipt(paths, &receipt)?;
    let latest = owner_state(paths)?.operation.context("operation missing")?;
    ensure!(
        state::same_operation(op, &latest) && latest.health_approved && !latest.cancelled,
        "confirmation cancelled"
    );
    canary_valid(op, path)?;
    ensure!(
        state::snapshot()? == op.new && state::native_alive(&receipt)?,
        "confirmation identity changed"
    );
    fs::remove_file(path)?;
    File::open(&op.temp)?.sync_all()?;
    logging::event("confirmed", op.host, Some(&op.commit), "confirm", Some(0));
    Ok(0)
}
pub fn native(args: NativeArgs) -> Result<i32> {
    ensure!(
        unsafe { libc::geteuid() } == 0,
        "native helper requires root"
    );
    identity(args.host, &args.profile, &args.system, &args.owner)?;
    let paths = Paths::installed()?;
    let op = owner_state(&paths)?
        .operation
        .context("operation missing")?;
    bound(&op, args.host, &args.profile, &args.system)?;
    ensure!(!op.cancelled, "operation cancelled");
    let activate = state::activation_arguments(&op);
    let wait = wait_arguments(&op);
    let executable = op.new.profile.join("activate-rs").display().to_string();
    if args.args == ["rm".to_owned(), state::canary(&op)?.display().to_string()] {
        return remove_canary(&paths, &op, &state::canary(&op)?);
    }
    ensure!(
        args.args.first() == Some(&executable),
        "unexpected native executable"
    );
    let tail = &args.args[1..];
    if tail == wait {
        let mut child = {
            let _lock = state::root_lock(&paths)?;
            let _record_lock = owner_record_lock(&paths)?;
            let latest = owner_state(&paths)?
                .operation
                .context("operation missing")?;
            ensure!(
                state::same_operation(&op, &latest) && !latest.cancelled,
                "wait eligibility changed"
            );
            if let Some(receipt) = state::receipt(&paths)? {
                ensure!(
                    !(receipt.terminal && state::same_operation(&receipt.operation, &op)),
                    "activation already terminal"
                );
            }
            ensure_temp(&paths, &op)?;
            command(&op, &wait)?.spawn()?
        };
        loop {
            match child.wait() {
                Ok(status) => return status.code().context("waiter terminated by signal"),
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(error) => return Err(error.into()),
            }
        }
    }
    ensure!(tail == activate, "unsupported native command");
    // Admission and the durable cancellation fence share the owner record lock.
    ensure!(
        unsafe { libc::signal(libc::SIGHUP, libc::SIG_IGN) } != libc::SIG_ERR,
        "cannot ignore HUP"
    );
    let mut activation = command(&op, &activate)?;
    let (mut child, mut receipt, persist_pid) = {
        let _lock = state::root_lock(&paths)?;
        let _record_lock = owner_record_lock(&paths)?;
        let latest = owner_state(&paths)?
            .operation
            .context("operation missing")?;
        ensure!(
            state::same_operation(&op, &latest) && !latest.cancelled,
            "activation eligibility changed"
        );
        if let Some(previous) = state::receipt(&paths)? {
            ensure!(
                previous.terminal && !state::same_operation(&previous.operation, &op),
                "unresolved native evidence"
            );
            validate_resolved(&paths, &previous)?;
            cleanup_temp(&paths, &previous)?;
        }
        ensure!(
            state::snapshot()? == op.old,
            "old system changed before activation"
        );
        ensure_temp(&paths, &op)?;
        let mut receipt = NativeReceipt {
            operation: latest,
            supervisor_pid: std::process::id(),
            child_pid: 0,
            exit_code: None,
            terminal: false,
            confirmed: false,
            snapshot: None,
        };
        logging::event("start", op.host, Some(&op.commit), "supervisor", None);
        let launch = (|| -> Result<std::process::Child> {
            state::write_receipt(&paths, &receipt)?;
            let latest = owner_state(&paths)?
                .operation
                .context("operation missing")?;
            ensure!(
                state::same_operation(&op, &latest)
                    && !latest.cancelled
                    && state::snapshot()? == op.old,
                "activation eligibility changed"
            );
            Ok(activation.spawn()?)
        })();
        let child = match launch {
            Ok(child) => child,
            Err(error) => {
                let attest = (|| -> Result<()> {
                    ensure!(state::snapshot()? == op.old, "prelaunch system changed");
                    receipt.terminal = true;
                    receipt.snapshot = Some(op.old.clone());
                    state::write_receipt(&paths, &receipt)
                })();
                if attest.is_err() || cleanup_temp(&paths, &receipt).is_err() {
                    logging::event("blocked", op.host, Some(&op.commit), "supervisor", None);
                }
                logging::event("failed", op.host, Some(&op.commit), "supervisor", None);
                return Err(error);
            }
        };
        receipt.child_pid = child.id();
        let persist_pid = state::write_receipt(&paths, &receipt);
        (child, receipt, persist_pid)
    };
    // No fallible early return after spawn: release admission locks, then reap.
    let status = loop {
        match child.wait() {
            Ok(status) => break Ok(status),
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => break Err(e),
        }
    };
    let actual = state::snapshot().ok();
    let terminal = (|| -> Result<()> {
        let _lock = state::root_lock(&paths)?;
        let latest = state::receipt(&paths)?.context("native receipt disappeared")?;
        ensure!(
            state::same_operation(&latest.operation, &op)
                && latest.supervisor_pid == receipt.supervisor_pid
                && !latest.terminal,
            "native receipt changed"
        );
        receipt.confirmed = latest.confirmed;
        receipt.exit_code = status.as_ref().ok().and_then(|s| s.code());
        receipt.terminal = status.is_ok();
        receipt.snapshot = if receipt.terminal { actual } else { None };
        state::write_receipt(&paths, &receipt)?;
        if receipt.terminal
            && receipt.exit_code.is_some()
            && receipt.snapshot.is_some()
            && cleanup_temp(&paths, &receipt).is_err()
        {
            logging::event(
                "blocked",
                op.host,
                Some(&op.commit),
                "supervisor",
                receipt.exit_code,
            );
        }
        Ok(())
    })();
    persist_pid?;
    terminal?;
    logging::event(
        "complete",
        op.host,
        Some(&op.commit),
        "supervisor",
        receipt.exit_code,
    );
    let code = status?
        .code()
        .context("native activation terminated by signal")?;
    if code == 0 {
        ensure!(
            receipt.confirmed && receipt.snapshot.as_ref() == Some(&op.new),
            "success lacks confirmation proof"
        );
    }
    Ok(code)
}
pub fn confirm(args: ConfirmArgs) -> Result<i32> {
    ensure!(
        unsafe { libc::geteuid() } == state::owner_uid()?,
        "confirmation requires Wave owner"
    );
    identity(args.host, &args.profile, &args.system, &args.owner)?;
    store_executable(&args.root_wrapper)?;
    let paths = Paths::installed()?;
    let op = state::load(&paths)?
        .operation
        .context("operation missing")?;
    bound(&op, args.host, &args.profile, &args.system)?;
    let mut streak = 0;
    loop {
        let next_sample = Instant::now() + Duration::from_secs(5);
        eligible(&paths, &op, &args.canary)?;
        let healthy = health::check(op.host).ok();
        eligible(&paths, &op, &args.canary)?;
        if healthy {
            streak += 1;
        } else {
            streak = 0;
        }
        if streak == 3 {
            break;
        }
        thread::sleep(next_sample.saturating_duration_since(Instant::now()));
    }
    state::update(&paths, |value| {
        eligible(&paths, &op, &args.canary)?;
        let current = value.operation.as_mut().context("operation missing")?;
        ensure!(
            state::same_operation(&op, current) && !current.cancelled && !current.health_approved,
            "operation no longer eligible"
        );
        current.health_approved = true;
        Ok(())
    })?;
    logging::event("health_passed", op.host, Some(&op.commit), "confirm", None);
    eligible(&paths, &op, &args.canary)?;
    let sudo = if cfg!(target_os = "macos") {
        "/usr/bin/sudo"
    } else {
        "/run/wrappers/bin/sudo"
    };
    let sudo_args: &[&str] = if args.host == Host::Ahri {
        &["-n", "-u", "root"]
    } else {
        &["-S", "-p", "", "-u", "root"]
    };
    let error = Command::new(sudo)
        .args(sudo_args)
        .arg(&args.root_wrapper)
        .arg("rm")
        .arg(&args.canary)
        .exec();
    bail!("cannot execute root confirmation helper: {error}")
}
