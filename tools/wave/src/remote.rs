use crate::{
    logging, presentation, process, source,
    state::{self, Paths},
};
use anyhow::{Context, Result, ensure};
use std::{
    io::{BufRead, BufReader, Read},
    process::{Command, ExitStatus, Stdio},
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

/// The Wave revision of the target's system profile (empty when unrecorded),
/// or None when the target cannot be reached.
fn active_revision(user: &str, hostname: &str) -> Option<String> {
    let output = process::capture(
        Command::new("ssh")
            .args([
                "-o",
                "BatchMode=yes",
                "-o",
                "ConnectTimeout=10",
                &format!("{user}@{hostname}"),
                "cat /nix/var/nix/profiles/system/etc/wave-os/revision 2>/dev/null || true",
            ])
            .stdin(Stdio::null()),
        Duration::from_secs(30),
    )
    .ok()?;
    output
        .success()
        .then(|| String::from_utf8(output.stdout).ok())
        .flatten()
        .map(|text| text.trim().to_owned())
}

/// Runs deploy-rs; with `prefix`, its output lines are labelled with the node,
/// so parallel deployments stay readable.
fn deploy_rs(paths: &Paths, flake: &str, node: &str, prefix: bool) -> Result<ExitStatus> {
    let mut command = Command::new("deploy");
    command
        .args(["--skip-checks", "--remote-build"])
        .arg(format!("{flake}#{node}"))
        .current_dir(&paths.source)
        .stdin(Stdio::null());
    if !prefix {
        return command.status().context("cannot start deploy-rs");
    }
    let mut child = command
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .context("cannot start deploy-rs")?;
    let stdout = child
        .stdout
        .take()
        .context("deploy-rs output unavailable")?;
    let stderr = child
        .stderr
        .take()
        .context("deploy-rs output unavailable")?;
    std::thread::scope(|scope| {
        for stream in [
            Box::new(stdout) as Box<dyn Read + Send>,
            Box::new(stderr) as Box<dyn Read + Send>,
        ] {
            scope.spawn(move || {
                for line in BufReader::new(stream).lines().map_while(Result::ok) {
                    eprintln!("{node}: {line}");
                }
            });
        }
    });
    Ok(child.wait()?)
}

pub enum Outcome {
    Current,
    Deployed,
    Failed,
    Unreachable,
}

fn valid_node(node: &str) -> Result<()> {
    ensure!(
        !node.is_empty()
            && node
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_'),
        "invalid node name"
    );
    Ok(())
}

/// Deploys `commit`, already checked out in the source copy, to `node`.
pub fn deploy_commit(paths: &Paths, node: &str, commit: &str, prefix: bool) -> Result<Outcome> {
    valid_node(node)?;
    let flake = source::flake(paths, commit);

    presentation::detail(&format!("Evaluating {node}"));
    let node_attribute = format!("deploy.nodes.{node}");
    let hostname = nix_eval(&flake, &format!("{node_attribute}.hostname"))?;
    let user = nix_eval(&flake, &format!("{node_attribute}.sshUser"))?;
    let Some(active) = active_revision(&user, &hostname) else {
        presentation::warning(&format!("{node} is unreachable as {user}@{hostname}"));
        return Ok(Outcome::Unreachable);
    };
    // Every commit changes the closure, so its revision identifies the system
    // without evaluating it here; deploy-rs evaluates it once below.
    if active == commit {
        presentation::success(&format!(
            "{node} already runs this system; nothing to activate"
        ));
        logging::event("success", node, Some(commit), "deploy", Some(0));
        return Ok(Outcome::Current);
    }

    // deploy-rs output stays visible: errors must be seen by whoever deploys.
    let status = deploy_rs(paths, &flake, node, prefix)?;
    if status.success() {
        logging::event("success", node, Some(commit), "deploy", Some(0));
        presentation::success(&format!("{node} is running {} and healthy", &commit[..8]));
        Ok(Outcome::Deployed)
    } else {
        logging::event("failed", node, Some(commit), "deploy", status.code());
        presentation::error(&format!(
            "{node} deployment failed; deploy-rs restores the previous system when activation or health fails"
        ));
        Ok(Outcome::Failed)
    }
}

pub fn deploy(paths: &Paths, node: &str) -> Result<i32> {
    valid_node(node)?;
    presentation::heading(&format!("deploy · {node}"));
    let _lock = state::operation_lock(paths)?;
    logging::event("start", node, None, "deploy", None);
    let commit = source::refresh(paths)?;
    presentation::revision("Latest main", &commit);
    Ok(match deploy_commit(paths, node, &commit, false)? {
        Outcome::Current | Outcome::Deployed => 0,
        Outcome::Failed | Outcome::Unreachable => 30,
    })
}
