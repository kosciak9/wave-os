use crate::{
    health, logging,
    model::*,
    presentation, process, source,
    state::{self, Paths},
};
use anyhow::{Context, Result, bail, ensure};
use std::{
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::Duration,
};

const SUDO: &str = if cfg!(target_os = "macos") {
    "/usr/bin/sudo"
} else {
    "/run/wrappers/bin/sudo"
};

/// Deploy targets switch to their deploy-rs profile, so every generation
/// carries the activation script deploy-rs needs to roll back to it.
fn system_attribute(flake: &str, host: &str) -> Result<String> {
    let output = process::capture(
        Command::new("nix")
            .args([
                "--extra-experimental-features",
                "nix-command flakes",
                "eval",
                "--json",
                &format!("{flake}#deploy.nodes"),
                "--apply",
                &format!("nodes: nodes ? \"{host}\""),
            ])
            .stdin(Stdio::null()),
        Duration::from_secs(600),
    )?;
    ensure!(output.success(), "cannot evaluate deploy nodes");
    Ok(if output.stdout.trim_ascii() == b"true" {
        format!("deploy.nodes.{host}.profiles.system.path")
    } else if cfg!(target_os = "macos") {
        format!("darwinConfigurations.{host}.system")
    } else {
        format!("nixosConfigurations.{host}.config.system.build.toplevel")
    })
}

/// sudo's secure_path may not contain Nix, so it receives an absolute nix-env.
fn nix_env() -> Result<PathBuf> {
    [
        "/run/current-system/sw/bin",
        "/nix/var/nix/profiles/default/bin",
    ]
    .iter()
    .map(|directory| Path::new(directory).join("nix-env"))
    .find(|path| path.is_file())
    .context("nix-env is unavailable")
}

fn build(flake: &str, host: &str) -> Result<PathBuf> {
    // Nix progress and errors stay on the terminal; only the out path is captured.
    let output = Command::new("nix")
        .args([
            "--extra-experimental-features",
            "nix-command flakes",
            "build",
            "--no-link",
            "--print-out-paths",
        ])
        .arg(format!("{flake}#{}", system_attribute(flake, host)?))
        .stdin(Stdio::null())
        .stderr(Stdio::inherit())
        .output()
        .context("cannot start nix build")?;
    ensure!(output.status.success(), "system build failed");
    let system = PathBuf::from(String::from_utf8(output.stdout)?.trim());
    ensure!(
        state::valid_store_path(&system),
        "nix build returned an unexpected path"
    );
    Ok(system)
}

fn sudo(arguments: &[&std::ffi::OsStr]) -> Result<bool> {
    // -H: root's HOME, which Nix and darwin activation expect.
    Ok(Command::new(SUDO)
        .arg("-H")
        .args(arguments)
        .current_dir("/")
        .status()
        .context("cannot start sudo")?
        .success())
}

/// Points the system profile at `system` and activates it.
fn activate(system: &Path) -> Result<bool> {
    let nix_env = nix_env()?;
    if !sudo(&[
        nix_env.as_os_str(),
        "--profile".as_ref(),
        PROFILE.as_ref(),
        "--set".as_ref(),
        system.as_os_str(),
    ])? {
        return Ok(false);
    }
    if cfg!(target_os = "macos") {
        sudo(&[system.join("activate").as_os_str()])
    } else {
        sudo(&[
            system.join("bin/switch-to-configuration").as_os_str(),
            "switch".as_ref(),
        ])
    }
}

fn show_changes(current: &Path, new: &Path) {
    let _ = Command::new("nvd")
        .arg("diff")
        .args([current, new])
        .stdin(Stdio::null())
        .status();
}

pub fn switch(paths: &Paths, host: &str) -> Result<i32> {
    presentation::heading(&format!("switch · {host}"));
    let _lock = state::operation_lock(paths)?;

    presentation::section("Source");
    logging::event("start", host, None, "source", None);
    let commit = source::refresh(paths)?;
    presentation::revision("Latest main", &commit);

    presentation::section("Build");
    logging::event("start", host, Some(&commit), "build", None);
    let new = build(&source::flake(paths, &commit), host)?;
    ensure!(
        source::revision(&new)?.as_deref() == Some(commit.as_str()),
        "built system does not record revision {commit}"
    );
    let current = Path::new(CURRENT).canonicalize()?;
    let previous = Path::new(PROFILE).canonicalize()?;
    if previous == new && source::revision(&current)?.as_deref() == Some(commit.as_str()) {
        presentation::success("System is already current; nothing to activate");
        logging::event("success", host, Some(&commit), "activation", Some(0));
        return Ok(0);
    }
    ensure!(
        state::valid_store_path(&previous),
        "current system profile is not a store path"
    );
    show_changes(&current, &new);

    presentation::section("Activation");
    logging::event("start", host, Some(&commit), "activation", None);
    let activated = activate(&new)?;
    let healthy = if activated {
        presentation::section("Health");
        health::wait(Path::new(health::MANIFEST), Duration::from_secs(120), 3)
    } else {
        presentation::error("Activation failed");
        false
    };
    if healthy {
        logging::event("success", host, Some(&commit), "health", Some(0));
        presentation::success(&format!("Running {} and healthy", &commit[..8]));
        return Ok(0);
    }

    presentation::section("Rollback");
    logging::event("start", host, Some(&commit), "rollback", None);
    if !activate(&previous)? {
        logging::event("failed", host, Some(&commit), "rollback", Some(1));
        bail!(
            "rollback to {} failed; the system may be partially switched",
            previous.display()
        );
    }
    let report = health::check();
    health::print(&report);
    logging::event("restored", host, Some(&commit), "rollback", Some(30));
    if report.ok() {
        presentation::warning("Previous system restored and healthy");
    } else {
        presentation::error("Previous system restored but unhealthy");
    }
    Ok(30)
}
