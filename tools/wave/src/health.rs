use crate::process;
use anyhow::Context;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

pub const MANIFEST: &str = "/etc/wave-os/health.json";
const PROBE_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Manifest {
    checks: BTreeMap<String, PathBuf>,
}

#[derive(Debug, Serialize)]
pub struct Health {
    pub ok: bool,
    pub summary: &'static str,
    pub checks: BTreeMap<String, Probe>,
}

impl Health {
    pub fn ok(&self) -> bool {
        self.ok
    }
}

#[derive(Debug, Serialize)]
pub struct Probe {
    pub ok: bool,
    pub summary: &'static str,
}

fn probe(executable: &Path) -> bool {
    process::capture(
        Command::new(executable)
            .stdin(Stdio::null())
            .stderr(Stdio::null()),
        PROBE_TIMEOUT,
    )
    .is_ok_and(|output| output.success())
}

/// Runs every probe of a manifest in parallel; an unreadable manifest is unhealthy.
pub fn check_manifest(path: &Path) -> Health {
    let manifest = std::fs::read(path)
        .context("health manifest unavailable")
        .and_then(|bytes| Ok(serde_json::from_slice::<Manifest>(&bytes)?));
    let mut checks = BTreeMap::new();
    let mut ok = false;
    if let Ok(manifest) = manifest {
        std::thread::scope(|scope| {
            let running: Vec<_> = manifest
                .checks
                .iter()
                .map(|(name, executable)| (name, scope.spawn(|| probe(executable))))
                .collect();
            for (name, handle) in running {
                let healthy = handle.join().unwrap_or(false);
                checks.insert(
                    name.clone(),
                    Probe {
                        ok: healthy,
                        summary: if healthy { "healthy" } else { "unhealthy" },
                    },
                );
            }
        });
        ok = checks.values().all(|probe| probe.ok);
    }
    Health {
        ok,
        summary: if ok { "host healthy" } else { "host unhealthy" },
        checks,
    }
}

pub fn check() -> Health {
    check_manifest(Path::new(MANIFEST))
}

pub fn print(report: &Health) {
    crate::presentation::health_table(
        report
            .checks
            .iter()
            .map(|(name, probe)| (name.as_str(), probe.ok)),
        report.ok(),
    );
}

/// Services restarted by activation need a moment before the first probe.
const SETTLE: Duration = Duration::from_secs(5);

/// Waits until the host passes `streak` consecutive checks, or fails at the deadline.
pub fn wait(manifest: &Path, timeout: Duration, streak: u32) -> bool {
    let deadline = Instant::now() + timeout;
    let mut passed = 0;
    std::thread::sleep(SETTLE);
    loop {
        let sample = Instant::now() + Duration::from_secs(5);
        let report = check_manifest(manifest);
        if report.ok() {
            passed += 1;
            eprintln!("wave: health check passed ({passed}/{streak})");
        } else {
            passed = 0;
            let failing: Vec<_> = report
                .checks
                .iter()
                .filter(|(_, probe)| !probe.ok)
                .map(|(name, _)| name.as_str())
                .collect();
            eprintln!(
                "wave: health check failed: {}",
                if failing.is_empty() {
                    "manifest unavailable".to_owned()
                } else {
                    failing.join(", ")
                }
            );
        }
        if passed >= streak {
            return true;
        }
        if sample >= deadline {
            return false;
        }
        std::thread::sleep(sample.saturating_duration_since(Instant::now()));
    }
}
