use crate::{
    github::{Ci, GitHub},
    presentation,
    remote::{self, Outcome},
    source,
    state::{self, Paths},
    switch,
};
use anyhow::Result;
use std::{
    collections::BTreeMap,
    fs::{self, OpenOptions},
    io::Write,
    os::unix::fs::OpenOptionsExt,
};

const ATTEMPTS: &str = "autodeploy.json";

/// The last commit tried on each node; a failed commit is not retried.
fn load(paths: &Paths) -> BTreeMap<String, String> {
    fs::read(paths.cli.join(ATTEMPTS))
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default()
}

fn save(paths: &Paths, attempts: &BTreeMap<String, String>) -> Result<()> {
    let temporary = paths.cli.join(format!("{ATTEMPTS}.tmp"));
    let mut file = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&temporary)?;
    file.write_all(&serde_json::to_vec(attempts)?)?;
    file.sync_all()?;
    fs::rename(temporary, paths.cli.join(ATTEMPTS))?;
    Ok(())
}

/// One tick: once CI passes on latest main, this host switches to it first;
/// the other nodes follow on a later tick, in parallel. Unreachable nodes are
/// retried on the next tick, failed ones only on a new commit.
pub fn run(paths: &Paths, host: &str, nodes: &[String]) -> Result<i32> {
    presentation::heading(&format!("autodeploy · {host}"));
    let _lock = state::operation_lock(paths)?;
    let github = GitHub::from_credentials();
    if !github.reports() {
        presentation::warning("No GitHub token; deployment statuses are not reported");
    }
    let source::Update {
        available: commit,
        current,
        ci,
    } = source::inspect(paths, &github)?;
    presentation::revision("Latest main", &commit);
    match ci {
        Ci::Pending => {
            presentation::detail("CI has not finished on latest main");
            return Ok(0);
        }
        Ci::Failed => {
            presentation::warning("CI failed on latest main; nothing to deploy");
            return Ok(0);
        }
        Ci::Passed => {}
    }

    let mut attempts = load(paths);
    if current.as_deref() != Some(commit.as_str()) && attempts.get(host) != Some(&commit) {
        let switched = switch::switch_to(paths, host, &commit, true);
        attempts.insert(host.to_owned(), commit.clone());
        save(paths, &attempts)?;
        let success = matches!(switched, Ok(0));
        if let Err(error) = &switched {
            presentation::error(&format!("{error:#}"));
        }
        github.report(
            &commit,
            host,
            success,
            if success {
                "Running and healthy"
            } else {
                "Switch failed"
            },
        );
        // The other nodes wait for a later tick, run by the deployer just activated.
        return Ok(if success { 0 } else { 30 });
    }

    let pending: Vec<_> = nodes
        .iter()
        .filter(|node| *node != host && attempts.get(*node) != Some(&commit))
        .collect();
    if pending.is_empty() {
        presentation::success("Every node has seen latest main");
        return Ok(0);
    }
    let outcomes: Vec<_> = std::thread::scope(|scope| {
        let running: Vec<_> = pending
            .iter()
            .map(|node| {
                (
                    *node,
                    scope.spawn(|| remote::deploy_commit(paths, node, &commit, true)),
                )
            })
            .collect();
        running
            .into_iter()
            .map(|(node, handle)| {
                let outcome = handle
                    .join()
                    .unwrap_or_else(|_| Err(anyhow::anyhow!("deployment of {node} panicked")));
                (node, outcome)
            })
            .collect()
    });

    let mut code = 0;
    for (node, outcome) in outcomes {
        let (success, description) = match outcome {
            Ok(Outcome::Unreachable) => continue,
            Ok(Outcome::Current) => (true, "Already running this system"),
            Ok(Outcome::Deployed) => (true, "Running and healthy"),
            Ok(Outcome::Failed) => (false, "Deployment failed"),
            Err(error) => {
                presentation::error(&format!("{node}: {error:#}"));
                (false, "Deployment failed before activation")
            }
        };
        if !success {
            code = 30;
        }
        attempts.insert(node.clone(), commit.clone());
        github.report(&commit, node, success, description);
    }
    save(paths, &attempts)?;
    Ok(code)
}
