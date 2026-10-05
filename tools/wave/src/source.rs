use crate::{
    model::*,
    process,
    state::{self, Paths},
};
use anyhow::{Context, Result, ensure};
use std::{
    fs,
    io::Read,
    os::unix::{
        fs::{MetadataExt, OpenOptionsExt},
        process::CommandExt,
    },
    path::Path,
    process::{Command, Stdio},
    time::Duration,
};

const UPSTREAM: &str = "https://github.com/kosciak9/wave-os.git";

fn command(repo: &Path) -> Command {
    let mut command = Command::new("git");
    command
        .args([
            "-c",
            "core.hooksPath=/dev/null",
            "-c",
            "core.fsmonitor=false",
        ])
        .current_dir(repo)
        .stdin(Stdio::null())
        .env("GIT_TERMINAL_PROMPT", "0");
    for name in [
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    ] {
        command.env_remove(name);
    }
    unsafe {
        command.pre_exec(|| {
            libc::umask(0o077);
            Ok(())
        });
    }
    command
}

fn git(repo: &Path, args: &[&str]) -> Result<String> {
    let output = process::capture(command(repo).args(args), Duration::from_secs(120))?;
    ensure!(
        output.code == 0 && !output.interrupted && !output.timed_out,
        "source operation failed"
    );
    Ok(String::from_utf8(output.stdout)?.trim().to_owned())
}

pub fn clean(repo: &Path, commit: &str) -> Result<()> {
    ensure!(
        sha40(commit) && git(repo, &["rev-parse", "HEAD"])? == commit,
        "source revision changed"
    );
    ensure!(
        git(repo, &["status", "--porcelain", "--untracked-files=all"])?.is_empty(),
        "deployment source is dirty"
    );
    for overlay in ["devenv.local.nix", "devenv.local.yaml"] {
        ensure!(
            !repo.join(overlay).try_exists()?,
            "local deployment overlays are unsupported"
        );
    }
    Ok(())
}

pub fn refresh(paths: &Paths) -> Result<String> {
    state::directory(&paths.source, state::owner_uid()?, 0o700)?;
    if fs::read_dir(&paths.source)?.next().is_none() {
        let parent = paths.source.parent().context("source parent missing")?;
        let output = process::capture(
            command(parent)
                .args([
                    "clone",
                    "--depth",
                    "1",
                    "--single-branch",
                    "--branch",
                    "main",
                    "--no-tags",
                    "--no-checkout",
                    UPSTREAM,
                ])
                .arg(&paths.source),
            Duration::from_secs(120),
        )?;
        ensure!(
            output.code == 0 && !output.interrupted && !output.timed_out,
            "cannot initialize deployment source"
        );
    } else {
        let git_dir = paths.source.join(".git");
        let metadata = fs::symlink_metadata(&git_dir)?;
        ensure!(
            metadata.is_dir()
                && metadata.uid() == state::owner_uid()?
                && metadata.mode() & 0o022 == 0
                && git_dir.canonicalize()? == git_dir,
            "unsafe source repository"
        );
        ensure!(
            git(&paths.source, &["rev-parse", "--show-toplevel"])?
                == paths.source.to_string_lossy(),
            "unexpected source repository"
        );
        ensure!(
            git(&paths.source, &["config", "--get", "remote.origin.url"])? == UPSTREAM,
            "unexpected deployment upstream"
        );
        let current = git(&paths.source, &["rev-parse", "HEAD"])?;
        clean(&paths.source, &current)?;
        git(
            &paths.source,
            &[
                "fetch",
                "--depth",
                "1",
                "--no-tags",
                "origin",
                "+refs/heads/main:refs/remotes/origin/main",
            ],
        )?;
    }
    let commit = git(&paths.source, &["rev-parse", "refs/remotes/origin/main"])?;
    ensure!(sha40(&commit), "upstream revision is invalid");
    git(&paths.source, &["checkout", "--detach", &commit])?;
    let metadata = fs::symlink_metadata(paths.source.join(".git"))?;
    ensure!(
        metadata.is_dir() && metadata.uid() == state::owner_uid()? && metadata.mode() & 0o022 == 0,
        "unsafe cloned repository"
    );
    clean(&paths.source, &commit)?;
    Ok(commit)
}

pub fn validation_copy(repo: &Path, commit: &str, destination: &Path) -> Result<()> {
    clean(repo, commit)?;
    let url = format!("file://{}", repo.display());
    git(
        repo,
        &[
            "clone",
            "--depth",
            "1",
            "--single-branch",
            "--no-tags",
            &url,
            destination
                .to_str()
                .context("invalid validation directory")?,
        ],
    )?;
    clean(destination, commit)
}

pub fn revision(system: &Path) -> Result<Option<String>> {
    let marker = system.join("etc/wave-os/revision");
    if !marker.try_exists()? {
        return Ok(None);
    }
    let resolved = marker.canonicalize()?;
    ensure!(
        resolved.starts_with("/nix/store"),
        "revision marker is outside the store"
    );
    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(resolved)?;
    let metadata = file.metadata()?;
    ensure!(
        metadata.is_file()
            && metadata.uid() == 0
            && metadata.mode() & 0o022 == 0
            && metadata.len() <= 128,
        "unsafe revision marker"
    );
    let mut value = String::new();
    file.take(129).read_to_string(&mut value)?;
    let value = value.trim();
    if value == "unknown" {
        return Ok(None);
    }
    ensure!(sha40(value), "invalid active revision");
    Ok(Some(value.into()))
}

pub fn check(paths: &Paths, host: Host, json: bool) -> Result<i32> {
    let _lock = state::operation_lock(paths, true)?;
    crate::logging::event("start", host, None, "source", None);
    let available = refresh(paths)?;
    let system = Path::new(CURRENT).canonicalize()?;
    ensure!(state::valid_store_path(&system), "invalid active system");
    let current = revision(&system)?;
    let (status, code) = match current.as_deref() {
        Some(value) if value == available => ("current", 0),
        Some(_) => ("update_available", 1),
        None => ("active_revision_unknown", 2),
    };
    crate::logging::event("complete", host, Some(&available), "status", Some(code));
    if json {
        println!(
            "{}",
            serde_json::json!({"status": status, "current": current, "available": available})
        );
    } else {
        println!("Wave: {status}; main={available}");
        if let Some(current) = current {
            println!("Active revision: {current}");
        }
    }
    Ok(code)
}
