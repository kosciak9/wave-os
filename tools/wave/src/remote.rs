use crate::{
    logging, presentation, process, source,
    state::{self, Paths},
};
use anyhow::{Context, Result, ensure};
use std::{
    process::{Command, Stdio},
    time::Duration,
};

fn nix_eval(flake: &str, attribute: &str) -> Result<String> {
    let output = process::capture(
        Command::new("nix")
            .args([
                "--extra-experimental-features",
                "nix-command flakes",
                "eval",
                "--raw",
                &format!("{flake}#{attribute}"),
            ])
            .stdin(Stdio::null()),
        Duration::from_secs(600),
    )?;
    ensure!(output.success(), "cannot evaluate {attribute}");
    Ok(String::from_utf8(output.stdout)?)
}

/// The target's active system profile, or None when it cannot be read.
fn active_profile(user: &str, hostname: &str) -> Option<String> {
    let output = process::capture(
        Command::new("ssh")
            .args([
                "-o",
                "BatchMode=yes",
                "-o",
                "ConnectTimeout=10",
                &format!("{user}@{hostname}"),
                "readlink -f /nix/var/nix/profiles/system",
            ])
            .stdin(Stdio::null())
            .stderr(Stdio::null()),
        Duration::from_secs(30),
    )
    .ok()?;
    output
        .success()
        .then(|| String::from_utf8(output.stdout).ok())
        .flatten()
        .map(|text| text.trim().to_owned())
}

pub fn deploy(paths: &Paths, node: &str) -> Result<i32> {
    ensure!(
        !node.is_empty()
            && node
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_'),
        "invalid node name"
    );
    presentation::heading(&format!("deploy · {node}"));
    let _lock = state::operation_lock(paths)?;
    logging::event("start", node, None, "deploy", None);
    let commit = source::refresh(paths)?;
    presentation::revision("Latest main", &commit);
    let flake = source::flake(paths, &commit);

    presentation::detail("Evaluating node");
    let node_attribute = format!("deploy.nodes.{node}");
    let hostname = nix_eval(&flake, &format!("{node_attribute}.hostname"))?;
    let user = nix_eval(&flake, &format!("{node_attribute}.sshUser"))?;
    let wanted = nix_eval(&flake, &format!("{node_attribute}.profiles.system.path"))?;
    if active_profile(&user, &hostname).as_deref() == Some(wanted.as_str()) {
        presentation::success(&format!(
            "{node} already runs this system; nothing to activate"
        ));
        logging::event("success", node, Some(&commit), "deploy", Some(0));
        return Ok(0);
    }

    // deploy-rs output stays on the terminal: errors must be visible to whoever deploys.
    let status = Command::new("deploy")
        .args(["--skip-checks", "--remote-build"])
        .arg(format!("{flake}#{node}"))
        .current_dir(&paths.source)
        .status()
        .context("cannot start deploy-rs")?;
    if status.success() {
        logging::event("success", node, Some(&commit), "deploy", Some(0));
        presentation::success(&format!("{node} is running {} and healthy", &commit[..8]));
        Ok(0)
    } else {
        logging::event("failed", node, Some(&commit), "deploy", status.code());
        presentation::error(&format!(
            "{node} deployment failed; deploy-rs restores the previous system when activation or health fails"
        ));
        Ok(30)
    }
}
