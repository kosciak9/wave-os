use crate::{
    health, logging,
    model::*,
    process,
    state::{self, Paths},
};
use anyhow::{Context, Result, ensure};
use sha2::{Digest, Sha256};
use std::{
    thread,
    time::{Duration, Instant},
};

fn fingerprint(
    active: &State,
    receipt: &Option<NativeReceipt>,
    snapshot: &Snapshot,
) -> Result<String> {
    Ok(format!(
        "{:x}",
        Sha256::digest(serde_json::to_vec(&(active, receipt, snapshot))?)
    ))
}
pub fn run(paths: &Paths, accept_manual: Option<&str>) -> Result<i32> {
    if accept_manual.is_none() && !paths.cli.join("operation.lock").try_exists()? {
        ensure!(
            state::load(paths)?.operation.is_none() && state::receipt(paths)?.is_none(),
            "recovery lock missing with deployment evidence"
        );
        println!("Wave: no recovery state has been initialized.");
        return Ok(0);
    }
    let _lock = state::operation_lock(paths, accept_manual.is_some())?;
    let active = state::load(paths)?;
    let receipt = state::receipt(paths)?;
    let snapshot = state::snapshot()?;
    let proof = fingerprint(&active, &receipt, &snapshot)?;
    println!(
        "Wave recovery: operation={}, native={}, snapshot={}",
        if active.operation.is_some() {
            "pending"
        } else {
            "none"
        },
        match &receipt {
            None => "absent",
            Some(r) if state::prelaunch_failed(r) => "not_launched",
            Some(r) if r.terminal && r.exit_code.is_some() => "terminal",
            Some(_) => "unknown/running",
        },
        if active
            .operation
            .as_ref()
            .is_some_and(|op| op.new == snapshot)
        {
            "new"
        } else if active
            .operation
            .as_ref()
            .is_some_and(|op| op.old == snapshot)
        {
            "old"
        } else {
            "manual"
        }
    );
    println!("Recovery fingerprint: {proof}");
    let Some(accepted) = accept_manual else {
        return Ok(0);
    };
    ensure!(accepted == proof, "recovery fingerprint changed");
    let op = active.operation.as_ref().context("no pending operation")?;
    let native = receipt
        .as_ref()
        .filter(|native| state::same_operation(op, &native.operation));
    let verify_quiescence = || -> Result<()> {
        if let Some(native) = native {
            state::quiescent(native)
        } else {
            ensure!(
                op.cancelled,
                "no native evidence without a durable cancellation fence"
            );
            if let Some(previous) = &receipt {
                state::quiescent(previous)?;
            }
            state::no_operation_processes(op)
        }
    };
    verify_quiescence()?;
    let start = Instant::now();
    loop {
        let next_sample = Instant::now() + Duration::from_secs(5);
        ensure!(!process::cancelled(), "recovery interrupted");
        ensure!(
            state::load(paths)? == active
                && state::receipt(paths)? == receipt
                && state::snapshot()? == snapshot,
            "recovery evidence changed"
        );
        verify_quiescence()?;
        ensure!(health::check(op.host).ok(), "recovery health window failed");
        if start.elapsed() >= Duration::from_secs(60) {
            break;
        }
        thread::sleep(next_sample.saturating_duration_since(Instant::now()));
    }
    ensure!(
        state::receipt(paths)? == receipt && state::snapshot()? == snapshot,
        "recovery evidence changed"
    );
    verify_quiescence()?;
    state::update(paths, |value| {
        ensure!(
            *value == active && state::receipt(paths)? == receipt && state::snapshot()? == snapshot,
            "recovery evidence changed"
        );
        verify_quiescence()?;
        value.last_result = Some(ResultRecord {
            id: op.id.clone(),
            commit: op.commit.clone(),
            outcome: Outcome::Reconciled,
            snapshot: snapshot.clone(),
        });
        value.rollback_commit = if snapshot == op.old {
            Some(op.commit.clone())
        } else {
            None
        };
        value.operation = None;
        Ok(())
    })?;
    logging::event("reconciled", op.host, Some(&op.commit), "recovery", Some(0));
    println!("Wave recovery reconciled the verified active system.");
    Ok(0)
}
