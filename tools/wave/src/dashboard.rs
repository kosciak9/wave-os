use crate::presentation;
use anyhow::{Context, Result, bail};
use serde::Deserialize;
use std::process::Command;

const API: &str = "https://wave.exposed/api/apps";

#[derive(Deserialize)]
struct Registered {
    url: String,
}

#[derive(Deserialize)]
struct Failure {
    error: String,
}

/// Percent-encodes everything outside RFC 3986 unreserved characters, so a `/` in a branch
/// stays within its path segment.
fn segment(text: &str) -> String {
    text.bytes()
        .map(|b| {
            if b.is_ascii_alphanumeric() || b"-._~".contains(&b) {
                char::from(b).to_string()
            } else {
                format!("%{b:02X}")
            }
        })
        .collect()
}

fn request(method: &str, url: &str, body: Option<&str>) -> Result<(u16, Vec<u8>)> {
    let mut command = Command::new("curl");
    command
        .args([
            "-q",
            "--silent",
            "--show-error",
            "--proto",
            "=https",
            "--max-time",
            "10",
            "--request",
            method,
            "--write-out",
            "\n%{http_code}",
        ])
        .arg(url);
    if let Some(body) = body {
        command.args([
            "--header",
            "Content-Type: application/json",
            "--data-binary",
            body,
        ]);
    }
    let output = command.output().context("cannot start curl")?;
    if !output.status.success() {
        bail!(
            "dashboard unreachable: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    let split = output
        .stdout
        .iter()
        .rposition(|b| *b == b'\n')
        .context("dashboard response without status")?;
    let status = std::str::from_utf8(&output.stdout[split + 1..])?
        .parse()
        .context("dashboard response without status")?;
    Ok((status, output.stdout[..split].to_vec()))
}

fn failure(status: u16, body: &[u8]) -> anyhow::Error {
    match serde_json::from_slice::<Failure>(body) {
        Ok(failure) => anyhow::anyhow!("dashboard: {}", failure.error),
        Err(_) => anyhow::anyhow!("dashboard answered HTTP {status}"),
    }
}

/// Registers an app served by this host on `port`; prints its URL on stdout.
pub fn add(project: &str, branch: &str, port: u16) -> Result<i32> {
    let body = serde_json::json!({ "project": project, "branch": branch, "port": port });
    let (status, response) = request("POST", API, Some(&body.to_string()))?;
    if status != 200 {
        return Err(failure(status, &response));
    }
    let registered: Registered =
        serde_json::from_slice(&response).context("unexpected dashboard response")?;
    println!("{}", registered.url);
    Ok(0)
}

pub fn remove(project: &str, branch: &str) -> Result<i32> {
    let url = format!("{API}/{}/{}", segment(project), segment(branch));
    match request("DELETE", &url, None)? {
        (200, _) => {}
        (404, _) => presentation::detail(&format!("{project}/{branch} was not registered")),
        (status, response) => return Err(failure(status, &response)),
    }
    Ok(0)
}
