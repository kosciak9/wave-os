use crate::presentation;
use anyhow::{Context, Result, ensure};
use serde::Deserialize;
use std::{
    io::Write,
    process::{Command, Stdio},
};

const API: &str = "https://api.github.com/repos/kosciak9/wave-os";

#[derive(Clone, Copy, PartialEq)]
pub enum Ci {
    Pending,
    Passed,
    Failed,
}

#[derive(Deserialize)]
struct CheckRuns {
    total_count: usize,
    check_runs: Vec<CheckRun>,
}

#[derive(Deserialize)]
struct CheckRun {
    name: String,
    status: String,
    conclusion: Option<String>,
}

pub struct GitHub {
    token: Option<String>,
}

impl GitHub {
    /// The token comes from the systemd credential `github-token`; an empty one disables statuses.
    pub fn from_credentials() -> Self {
        let token = std::env::var_os("CREDENTIALS_DIRECTORY")
            .and_then(|directory| {
                std::fs::read_to_string(std::path::Path::new(&directory).join("github-token")).ok()
            })
            .map(|token| token.trim().to_owned())
            .filter(|token| !token.is_empty());
        // Checked here because the token is spliced into curl's configuration.
        let token = token.filter(|token| {
            let valid = token
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'_');
            if !valid {
                presentation::warning("GitHub token has unexpected characters");
            }
            valid
        });
        Self { token }
    }

    pub fn reports(&self) -> bool {
        self.token.is_some()
    }

    fn request(&self, method: &str, url: &str, body: Option<&str>) -> Result<Vec<u8>> {
        let mut command = Command::new("curl");
        command
            .args([
                "-q",
                "--silent",
                "--show-error",
                "--fail",
                "--proto",
                "=https",
                "--max-time",
                "30",
                // The token travels on stdin, never in the argument list.
                "--config",
                "-",
                "--request",
                method,
                "--header",
                "Accept: application/vnd.github+json",
                "--header",
                "X-GitHub-Api-Version: 2022-11-28",
            ])
            .arg(url)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped());
        if let Some(body) = body {
            command.args(["--data-binary", body]);
        }
        let mut child = command.spawn().context("cannot start curl")?;
        {
            let mut stdin = child.stdin.take().context("curl input unavailable")?;
            if let Some(token) = &self.token {
                writeln!(stdin, "header = \"Authorization: Bearer {token}\"")?;
            }
        }
        let output = child.wait_with_output()?;
        ensure!(output.status.success(), "GitHub {method} request failed");
        Ok(output.stdout)
    }

    /// Shared validation and this host's cache must pass; other hosts build independently.
    pub fn ci(&self, commit: &str, host: &str) -> Result<Ci> {
        let required: &[&str] = match host {
            "ahri" => &["nix-validate", "betterleaks", "ahri-cache"],
            "zac" => &["nix-validate", "betterleaks", "zac-cache"],
            "jayce" | "renekton" | "zilean" => &["nix-validate", "betterleaks"],
            _ => anyhow::bail!("no deployment CI policy for {host}"),
        };
        let body = self.request(
            "GET",
            &format!("{API}/commits/{commit}/check-runs?per_page=100"),
            None,
        )?;
        let runs: CheckRuns = serde_json::from_slice(&body)?;
        ensure!(
            runs.total_count == runs.check_runs.len(),
            "commit has more check runs than one page"
        );
        let mut pending = false;
        for name in required {
            // Missing checks are pending, never implicitly successful.
            let Some(run) = runs.check_runs.iter().find(|run| run.name == *name) else {
                pending = true;
                continue;
            };
            if run.status != "completed" {
                pending = true;
            } else if run.conclusion.as_deref() != Some("success") {
                return Ok(Ci::Failed);
            }
        }
        Ok(if pending { Ci::Pending } else { Ci::Passed })
    }

    /// Reports the deployment of `commit` to `node`; failures are only warned about.
    pub fn report(&self, commit: &str, node: &str, success: bool, description: &str) {
        if self.token.is_none() {
            return;
        }
        let body = serde_json::json!({
            "state": if success { "success" } else { "failure" },
            "context": format!("deploy/{node}"),
            "description": description,
        })
        .to_string();
        if let Err(error) = self.request("POST", &format!("{API}/statuses/{commit}"), Some(&body)) {
            presentation::warning(&format!("Cannot report {node} status: {error:#}"));
        }
    }
}
