use crate::{
    github::{Ci, GitHub},
    logging,
    model::*,
    presentation, process,
    state::{self, Paths},
};
use anyhow::{Context, Result, ensure};
use std::{
    fs,
    os::unix::process::CommandExt,
    path::Path,
    process::{Command, Stdio},
    time::Duration,
};

const UPSTREAM: &str = "https://github.com/kosciak9/wave-os.git";

fn git(repo: &Path, args: &[&str]) -> Result<String> {
    let mut command = Command::new("git");
    command
        .args([
            "-c",
            "core.hooksPath=/dev/null",
            "-c",
            "core.fsmonitor=false",
        ])
        .args(args)
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
    let output = process::capture(&mut command, Duration::from_secs(120))?;
    ensure!(output.success(), "git {} failed", args[0]);
    Ok(String::from_utf8(output.stdout)?.trim().to_owned())
}

/// The deployment source must be exactly `commit`, without local edits.
pub fn clean(repo: &Path, commit: &str) -> Result<()> {
    ensure!(
        git(repo, &["rev-parse", "HEAD"])? == commit,
        "deployment source moved away from {commit}"
    );
    ensure!(
        git(repo, &["status", "--porcelain", "--untracked-files=all"])?.is_empty(),
        "deployment source {} has local changes",
        repo.display()
    );
    Ok(())
}

/// Checks out the latest upstream main in the dedicated source copy.
pub fn refresh(paths: &Paths) -> Result<String> {
    presentation::detail("Fetching latest main");
    if fs::read_dir(&paths.source)?.next().is_none() {
        let parent = paths.source.parent().context("source parent missing")?;
        let source = paths.source.to_str().context("invalid source path")?;
        git(
            parent,
            &[
                "clone",
                "--quiet",
                "--depth",
                "1",
                "--single-branch",
                "--branch",
                "main",
                "--no-tags",
                "--no-checkout",
                UPSTREAM,
                source,
            ],
        )?;
    } else {
        ensure!(
            git(&paths.source, &["config", "--get", "remote.origin.url"])? == UPSTREAM,
            "deployment source does not track {UPSTREAM}"
        );
        let current = git(&paths.source, &["rev-parse", "HEAD"])?;
        clean(&paths.source, &current)?;
        git(
            &paths.source,
            &[
                "fetch",
                "--quiet",
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
    git(&paths.source, &["checkout", "--quiet", "--detach", &commit])?;
    clean(&paths.source, &commit)?;
    Ok(commit)
}

pub fn flake(paths: &Paths, commit: &str) -> String {
    format!(
        "git+file://{}?ref=refs/remotes/origin/main&rev={commit}&shallow=1",
        paths.source.display()
    )
}

/// The Wave revision a system closure was built from, if recorded.
pub fn revision(system: &Path) -> Result<Option<String>> {
    let marker = system.join("etc/wave-os/revision");
    if !marker.try_exists()? {
        return Ok(None);
    }
    let value = fs::read_to_string(marker)?;
    let value = value.trim();
    Ok(sha40(value).then(|| value.to_owned()))
}

/// Latest main, the revision this host runs, and whether CI passed on latest main.
pub struct Update {
    pub available: String,
    pub current: Option<String>,
    pub ci: Ci,
}

pub fn inspect(paths: &Paths, github: &GitHub) -> Result<Update> {
    let available = refresh(paths)?;
    let current = revision(&Path::new(CURRENT).canonicalize()?)?;
    let ci = github.ci(&available)?;
    Ok(Update {
        available,
        current,
        ci,
    })
}

pub fn check(paths: &Paths, host: &str, json: bool) -> Result<i32> {
    presentation::heading(&format!("check · {host}"));
    let _lock = state::operation_lock(paths)?;
    let update = inspect(paths, &GitHub::from_credentials())?;
    let (status, code) = match (update.current.as_deref(), update.ci) {
        (Some(value), _) if value == update.available => ("current", 0),
        (None, _) => ("active_revision_unknown", 2),
        (Some(_), Ci::Passed) => ("update_available", 1),
        (Some(_), Ci::Pending) => ("update_awaiting_ci", 3),
        (Some(_), Ci::Failed) => ("update_failed_ci", 4),
    };
    let ci = match update.ci {
        Ci::Passed => "passed",
        Ci::Pending => "pending",
        Ci::Failed => "failed",
    };
    logging::event(
        "complete",
        host,
        Some(&update.available),
        "status",
        Some(code),
    );
    if json {
        println!(
            "{}",
            serde_json::json!({
                "status": status,
                "current": update.current,
                "available": update.available,
                "ci": ci,
            })
        );
    } else {
        match code {
            0 => presentation::success("System is up to date"),
            1 => presentation::warning("An update is available on main"),
            2 => presentation::warning("The active system revision is unknown"),
            3 => presentation::warning("Main has changed; CI has not finished on it"),
            _ => presentation::warning("Main has changed, but CI failed on it"),
        }
        if let Some(current) = &update.current {
            presentation::revision("Active revision", current);
        }
        presentation::revision("Latest main", &update.available);
        presentation::detail(&format!("CI on latest main: {ci}"));
    }
    Ok(code)
}
