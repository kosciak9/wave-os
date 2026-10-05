use crate::{
    health, logging,
    model::*,
    presentation::{self, Completion, Progress, Step, Task},
    process, source,
    state::{self, Paths},
};
use anyhow::{Context, Result, ensure};
use serde::Deserialize;
use std::{
    fs,
    io::{BufRead, BufReader, Read, Write},
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::Command,
    thread,
    time::{Duration, Instant},
};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Metadata {
    hostname: String,
    ssh_user: String,
    profile_user: String,
    profile_path: String,
    profile_closure: PathBuf,
    system_closure: PathBuf,
    deploy_package: PathBuf,
    sudo_wrapper: PathBuf,
    expected_sudo: PathBuf,
    root_wrapper: PathBuf,
    source_revision: String,
    deploy_revision: String,
    temp_path: PathBuf,
    confirm_timeout: u64,
    activation_timeout: u64,
    auto_rollback: bool,
    magic_rollback: bool,
    interactive_sudo: bool,
    ssh_opts: Vec<String>,
}

fn quoted(value: &str) -> String {
    serde_json::to_string(value)
        .expect("string serialization")
        .replace("${", "\\${")
}

fn runtime_flake(
    repo: &Path,
    commit: &str,
    host: Host,
    temp: &Path,
    directory: &Path,
) -> Result<()> {
    let input = format!("git+file://{}?rev={commit}&shallow=1", repo.display());
    let target = host.name();
    let platform = host.platform();
    let system = match host {
        Host::Renekton => "source.darwinConfigurations.renekton.config.system.build.toplevel",
        Host::Jayce => "source.nixosConfigurations.jayce.config.system.build.toplevel",
    };
    let text = format!(
        r#"{{
  inputs.source.url = {input};
  outputs = {{ self, source }}: let
    node = source.deploy.nodes.{target} // {{ tempPath = {temp}; }};
  in {{
    deploy = {{ nodes.{target} = node; }};
    packages.{platform}.profile = node.profiles.system.path;
    packages.{platform}.deploy-rs = source.inputs.deploy-rs.packages.{platform}.deploy-rs;
    packages.{platform}.sudo = source.packages.{platform}.wave-deploy-sudo;
    checks.{platform} = source.inputs.deploy-rs.lib.{platform}.deployChecks self.deploy;
    waveMeta = {{
      hostname = node.hostname;
      ssh_user = node.sshUser;
      profile_user = node.profiles.system.user;
      profile_path = node.profiles.system.profilePath;
      profile_closure = toString node.profiles.system.path;
      system_closure = toString {system};
      deploy_package = toString self.packages.{platform}.deploy-rs;
      sudo_wrapper = node.sudo;
      expected_sudo = toString self.packages.{platform}.sudo;
      root_wrapper = toString source.packages.{platform}.wave-deploy-root;
      source_revision = if source ? rev then source.rev else null;
      deploy_revision = if source.inputs.deploy-rs ? rev then source.inputs.deploy-rs.rev else null;
      temp_path = node.tempPath;
      confirm_timeout = node.confirmTimeout;
      activation_timeout = node.activationTimeout;
      auto_rollback = node.autoRollback;
      magic_rollback = node.magicRollback;
      interactive_sudo = node.interactiveSudo;
      ssh_opts = node.sshOpts;
    }};
  }};
}}
"#,
        input = quoted(&input),
        temp = quoted(&temp.to_string_lossy())
    );
    fs::write(directory.join("flake.nix"), text)?;
    Ok(())
}

fn nix(repo: &Path, args: &[&str], capture: bool, task: Task) -> Result<process::Output> {
    let mut progress = Progress::new(task);
    let mut command = Command::new("devenv");
    command.args([
        "--quiet",
        "--option",
        "git-hooks.enable:bool",
        "false",
        "shell",
        "--",
    ]);
    if args.first() == Some(&"nix") {
        command
            .args(["nix", "--log-format", "internal-json", "--verbose"])
            .args(&args[1..]);
    } else {
        command.args(args);
    }
    command.current_dir(repo);
    process::run(
        &mut command,
        Duration::from_secs(1200),
        capture,
        || Ok(()),
        &mut progress,
        |_| {},
    )
}

fn passed(output: process::Output) -> Result<Vec<u8>> {
    ensure!(
        output.code == 0 && !output.interrupted && !output.timed_out,
        "validation or build failed"
    );
    Ok(output.stdout)
}

fn validate(meta: &Metadata, commit: &str, temp: &Path) -> Result<()> {
    ensure!(
        meta.hostname == "localhost"
            && meta.ssh_user == "kosciak"
            && meta.profile_user == "root"
            && meta.profile_path == PROFILE,
        "deployment target mismatch"
    );
    ensure!(
        meta.source_revision == commit && meta.deploy_revision == DEPLOY_REV,
        "deployment source pin mismatch"
    );
    ensure!(
        meta.temp_path == temp
            && meta.confirm_timeout == CONFIRM_TIMEOUT
            && meta.activation_timeout == ACTIVATION_TIMEOUT
            && meta.auto_rollback
            && meta.magic_rollback
            && meta.interactive_sudo,
        "deployment protocol mismatch"
    );
    ensure!(
        meta.sudo_wrapper == meta.expected_sudo,
        "deployment privilege adapter mismatch"
    );
    ensure!(
        meta.ssh_opts
            == [
                "-o",
                "BatchMode=yes",
                "-o",
                "StrictHostKeyChecking=yes",
                "-o",
                "ConnectionAttempts=1",
                "-o",
                "ConnectTimeout=5"
            ],
        "deployment transport safety mismatch"
    );
    for path in [
        &meta.profile_closure,
        &meta.system_closure,
        &meta.deploy_package,
    ] {
        ensure!(
            state::lexical_store_path(path),
            "invalid deployment closure"
        );
    }
    for path in [&meta.sudo_wrapper, &meta.root_wrapper] {
        let name = path.file_name().context("missing privilege wrapper name")?;
        ensure!(
            state::lexical_store_path(path) && name.to_string_lossy().contains("wave-deploy-root"),
            "invalid deployment adapter"
        );
    }
    Ok(())
}

fn fence(paths: &Paths, op: &Operation) -> Result<()> {
    state::update(paths, |value| {
        let current = value
            .operation
            .as_mut()
            .context("active operation missing")?;
        ensure!(
            state::same_operation(current, op),
            "active operation changed"
        );
        current.cancelled = true;
        Ok(())
    })
}

fn healthy_window(host: Host, expected: &Snapshot, seconds: u64) -> Result<()> {
    let mut progress = Progress::new(Task::RollbackHealth);
    let started = Instant::now();
    let result = (|| {
        loop {
            ensure!(
                state::snapshot()? == *expected
                    && health::check(host).ok()
                    && state::snapshot()? == *expected,
                "system is not stable and healthy"
            );
            if started.elapsed() >= Duration::from_secs(seconds) {
                return Ok(());
            }
            progress.tick();
            thread::sleep(Duration::from_secs(5));
        }
    })();
    progress.finish(if result.is_ok() {
        Completion::Success
    } else {
        Completion::Unavailable
    });
    result
}

fn finalize(paths: &Paths, op: &Operation, outcome: Outcome, snapshot: Snapshot) -> Result<()> {
    state::update(paths, |value| {
        let current = value
            .operation
            .as_ref()
            .context("active operation missing")?;
        ensure!(
            state::same_operation(current, op) && state::snapshot()? == snapshot,
            "terminal operation changed"
        );
        value.rollback_commit = if outcome == Outcome::Restored {
            Some(op.commit.clone())
        } else {
            None
        };
        value.last_result = Some(ResultRecord {
            id: op.id.clone(),
            commit: op.commit.clone(),
            outcome,
            snapshot,
        });
        value.operation = None;
        Ok(())
    })
}

fn observe(paths: &Paths, op: &Operation, cli_ok: bool) -> Result<i32> {
    let mut progress = Progress::new(Task::Observe);
    let deadline = Instant::now() + Duration::from_secs(ACTIVATION_TIMEOUT + CONFIRM_TIMEOUT + 120);
    loop {
        progress.tick();
        let receipt = state::receipt(paths)?;
        match receipt.filter(|r| state::same_operation(&r.operation, op)) {
            Some(receipt) if receipt.terminal => {
                if state::quiescent(&receipt).is_err() {
                    ensure!(
                        Instant::now() < deadline,
                        "native supervisor did not quiesce"
                    );
                    thread::sleep(Duration::from_millis(250));
                    continue;
                }
                let current = state::snapshot()?;
                let approved = state::load(paths)?.operation.is_some_and(|current| {
                    state::same_operation(&current, op) && current.health_approved
                });
                if cli_ok
                    && receipt.exit_code == Some(0)
                    && receipt.confirmed
                    && approved
                    && receipt.snapshot.as_ref() == Some(&op.new)
                    && current == op.new
                {
                    ensure!(
                        health::check(op.host).ok() && state::snapshot()? == current,
                        "confirmed system changed"
                    );
                    finalize(paths, op, Outcome::Success, current)?;
                    logging::event("success", op.host, Some(&op.commit), "deploy", Some(0));
                    progress.finish(Completion::Success);
                    presentation::success("Deployment confirmed; system is healthy");
                    return Ok(0);
                }
                if (receipt.exit_code.is_some_and(|code| code != 0)
                    || state::prelaunch_failed(&receipt))
                    && receipt.snapshot.as_ref() == Some(&op.old)
                    && current == op.old
                {
                    healthy_window(op.host, &op.old, 60)?;
                    state::quiescent(&receipt)?;
                    ensure!(
                        state::receipt(paths)?.as_ref() == Some(&receipt),
                        "native receipt changed"
                    );
                    finalize(paths, op, Outcome::Restored, current)?;
                    logging::event(
                        "restored",
                        op.host,
                        Some(&op.commit),
                        "rollback",
                        receipt.exit_code,
                    );
                    presentation::warning(
                        "Deployment failed; the previous system is restored and healthy",
                    );
                    return Ok(if process::cancelled() { 130 } else { 30 });
                }
                anyhow::bail!("terminal deployment cannot be safely classified");
            }
            None if !cli_ok => {
                // Root admission holds the same record lock as the cancellation fence.
                // No matching receipt after fencing means no native child can launch later.
                fence(paths, op)?;
                if state::no_operation_processes(op).is_ok() {
                    let latest = state::receipt(paths)?;
                    if !latest.is_some_and(|r| state::same_operation(&r.operation, op)) {
                        healthy_window(op.host, &op.old, 10)?;
                        state::no_operation_processes(op)?;
                        finalize(paths, op, Outcome::Restored, op.old.clone())?;
                        logging::event("restored", op.host, Some(&op.commit), "deploy", Some(30));
                        presentation::warning(
                            "No native activation was launched; the previous system is unchanged and healthy",
                        );
                        return Ok(if process::cancelled() { 130 } else { 30 });
                    }
                }
            }
            _ => (),
        }
        ensure!(
            Instant::now() < deadline,
            "native deployment outcome remains unknown"
        );
        thread::sleep(Duration::from_millis(250));
    }
}

fn rollback_approval(commit: &str, explicit: Option<&str>) -> Result<()> {
    if let Some(explicit) = explicit {
        ensure!(explicit == commit, "rollback approval revision mismatch");
        return Ok(());
    }
    let mut terminal = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open("/dev/tty")?;
    write!(
        terminal,
        "Wave: version {} was previously restored. Retry? Type TAK: ",
        &commit[..8]
    )?;
    terminal.flush()?;
    let mut answer = String::new();
    BufReader::new((&mut terminal).take(16)).read_line(&mut answer)?;
    ensure!(
        answer.trim_end_matches(['\r', '\n']) == "TAK",
        "rollback retry not approved"
    );
    Ok(())
}

pub fn switch(paths: &Paths, host: Host, approval: Option<&str>) -> Result<i32> {
    presentation::begin(host, "switch");
    if let Some(value) = approval {
        ensure!(sha40(value), "invalid rollback approval");
    }
    let _lock = state::operation_lock(paths, true)?;
    // Older native deployments use a different lock and may still be rolling back.
    let previous_marker = Path::new(if host == Host::Renekton {
        "/Users/kosciak/.local/state/wave/active.json"
    } else {
        "/home/kosciak/.local/state/wave/active.json"
    });
    match fs::symlink_metadata(previous_marker) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => (),
        _ => {
            logging::event("blocked", host, None, "recovery", Some(40));
            presentation::warning(
                "Wave: an earlier deployment has unresolved state; reconcile it with the previous CLI before upgrading.",
            );
            return Ok(40);
        }
    }
    let active = state::load(paths)?;
    if active.operation.is_some() {
        logging::event("blocked", host, None, "recovery", Some(40));
        presentation::warning("Unresolved deployment; inspect `wave recover` before retrying.");
        return Ok(40);
    }
    if let Some(receipt) = state::receipt(paths)? {
        state::quiescent(&receipt)?;
    }
    logging::event("start", host, None, "source", None);
    presentation::section(Step::Source);
    let commit = source::refresh(paths)?;
    presentation::revision("Source revision", &commit);
    if active.rollback_commit.as_deref() == Some(&commit) {
        rollback_approval(&commit, approval)?;
    } else {
        ensure!(
            approval.is_none(),
            "approval supplied for a different or non-restored version"
        );
    }
    let old = state::snapshot()?;
    if !old.profile.join("deploy-rs-activate").is_file() {
        presentation::warning(
            "Wave: current profile lacks deploy-rs rollback support; a supervised initial bootstrap is required.",
        );
        return Ok(10);
    }
    logging::event("start", host, Some(&commit), "preflight", None);
    presentation::section(Step::Preflight);
    ensure!(
        health::check(host).ok() && !process::cancelled(),
        "preflight health failed"
    );
    presentation::success("Current system is healthy");
    let runtime = tempfile::Builder::new().prefix("wave-").tempdir()?;
    fs::set_permissions(runtime.path(), fs::Permissions::from_mode(0o700))?;
    let validation = runtime.path().join("validation");
    presentation::section(Step::Validation);
    source::validation_copy(&paths.source, &commit, &validation)?;
    logging::event("start", host, Some(&commit), "validation", None);
    passed(nix(&validation, &["nix-check"], false, Task::StaticChecks)?)?;
    passed(nix(
        &validation,
        &["nix-eval", host.name()],
        false,
        Task::Evaluation,
    )?)?;
    source::clean(&paths.source, &commit)?;
    ensure!(
        state::snapshot()? == old,
        "system changed during validation"
    );
    let id = runtime
        .path()
        .file_name()
        .context("runtime identity missing")?
        .to_str()
        .context("invalid runtime identity")?
        .to_owned();
    let temp = paths.native.join(&id);
    let flake_directory = runtime.path().join("flake");
    fs::create_dir(&flake_directory)?;
    runtime_flake(&paths.source, &commit, host, &temp, &flake_directory)?;
    let flake = format!("path:{}", flake_directory.display());
    logging::event("start", host, Some(&commit), "prepare", None);
    presentation::section(Step::Preparation);
    passed(nix(
        &validation,
        &["nix", "flake", "lock", &flake],
        false,
        Task::RuntimeLock,
    )?)?;
    let meta: Metadata = serde_json::from_slice(&passed(nix(
        &validation,
        &[
            "nix",
            "eval",
            "--json",
            "--no-write-lock-file",
            &format!("{flake}#waveMeta"),
        ],
        true,
        Task::Metadata,
    )?)?)?;
    validate(&meta, &commit, &temp)?;
    logging::event("start", host, Some(&commit), "build", None);
    presentation::section(Step::Build);
    let targets = [
        format!("{flake}#profile"),
        format!("{flake}#deploy-rs"),
        format!("{flake}#sudo"),
    ];
    let args = [
        "nix",
        "build",
        "--no-link",
        "--no-write-lock-file",
        targets[0].as_str(),
        targets[1].as_str(),
        targets[2].as_str(),
    ];
    passed(nix(&validation, &args, false, Task::Build)?)?;
    let new = Snapshot {
        profile: meta.profile_closure,
        system: meta.system_closure,
    };
    state::validate_snapshot(&new)?;
    ensure!(
        source::revision(&new.system)?.as_deref() == Some(&commit),
        "new system lacks the exact source revision"
    );
    state::store_executable(&meta.root_wrapper)?;
    state::store_executable(&meta.sudo_wrapper)?;
    state::activator(&new.profile)?;
    source::clean(&paths.source, &commit)?;
    ensure!(
        state::snapshot()? == old && health::check(host).ok() && !process::cancelled(),
        "final preflight failed"
    );
    if new == old {
        logging::event("success", host, Some(&commit), "deploy", Some(0));
        presentation::section(Step::Activation);
        presentation::detail("Skipped: identical profile is already active");
        presentation::section(Step::Verification);
        presentation::success("System already current and healthy; no activation was needed");
        return Ok(0);
    }
    let op = Operation {
        id,
        host,
        commit: commit.clone(),
        old,
        new,
        temp,
        cancelled: false,
        health_approved: false,
    };
    state::update(paths, |value| {
        ensure!(
            value.operation.is_none() && state::snapshot()? == op.old,
            "deployment state changed"
        );
        value.operation = Some(op.clone());
        Ok(())
    })?;
    logging::event("deploy_started", host, Some(&commit), "deploy", None);
    presentation::section(Step::Activation);
    let mut progress = Progress::new(Task::Deploy);
    let mut last_observation = Instant::now() - Duration::from_secs(1);
    let cli = process::run(
        Command::new(meta.deploy_package.join("bin/deploy"))
            .args([
                "--no-progress",
                "--no-demarcate-output",
                &format!("{flake}#{}.system", host.name()),
                "--",
                "--no-write-lock-file",
                "--log-format",
                "internal-json",
                "--verbose",
            ])
            .current_dir(&paths.source),
        Duration::from_secs(1200),
        false,
        || fence(paths, &op),
        &mut progress,
        |progress| {
            if last_observation.elapsed() < Duration::from_secs(1) {
                return;
            }
            last_observation = Instant::now();
            // Read-only presentation: neither these observations nor Nix progress authorize activation.
            if let Ok(Some(receipt)) = state::receipt(paths)
                && state::same_operation(&receipt.operation, &op)
            {
                let phase = if receipt.confirmed {
                    presentation::section(Step::Verification);
                    Task::NativeCompletion
                } else if receipt.child_pid > 1
                    && state::snapshot().is_ok_and(|snapshot| snapshot == op.new)
                {
                    presentation::section(Step::Verification);
                    Task::HealthAuthorization
                } else if receipt.child_pid > 1 {
                    Task::NativeActivation
                } else {
                    Task::Deploy
                };
                progress.phase(phase);
            }
        },
    );
    let cli_ok = cli
        .as_ref()
        .is_ok_and(|r| r.code == 0 && !r.interrupted && !r.timed_out);
    if !cli_ok {
        fence(paths, &op)?;
    }
    logging::event(
        "deploy_finished",
        host,
        Some(&commit),
        "deploy",
        cli.as_ref().ok().map(|r| r.code),
    );
    presentation::section(Step::Verification);
    match observe(paths, &op, cli_ok) {
        Ok(code) => Ok(code),
        Err(_) => {
            logging::event("blocked", host, Some(&commit), "recovery", Some(40));
            presentation::error(
                "Wave: activation/rollback is not proven safe; pending state retained. Inspect `wave recover`.",
            );
            Ok(40)
        }
    }
}
