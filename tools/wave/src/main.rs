mod deploy;
mod health;
mod logging;
mod model;
mod native;
mod presentation;
mod process;
mod recover;
mod source;
mod state;

use anyhow::{Result, ensure};
use clap::{Parser, Subcommand};
use model::Host;

#[derive(Parser)]
#[command(
    name = "wave",
    version,
    about = "Wave OS source and safe local deployments"
)]
struct Cli {
    #[command(subcommand)]
    command: Action,
}

#[derive(Subcommand)]
enum Action {
    /// Fetch main and detect updates; exit 0=current, 1=available, 2=unknown revision
    Check {
        #[arg(long)]
        json: bool,
    },
    /// Fetch, validate and safely deploy the local host through deploy-rs
    Switch {
        #[arg(long, value_name = "FULL_SHA40")]
        approve_rollback: Option<String>,
    },
    /// Inspect interrupted deployment; explicit acceptance requires its fingerprint
    Recover {
        #[arg(long, value_name = "PLAN_SHA256")]
        accept_manual: Option<String>,
    },
    /// Read-only health checks for the local host
    Health {
        #[arg(long)]
        json: bool,
    },
    #[command(name = "__native", hide = true)]
    Native(native::NativeArgs),
    #[command(name = "__confirm", hide = true)]
    Confirm(native::ConfirmArgs),
}

fn local_host() -> Result<Host> {
    ensure!(
        unsafe { libc::geteuid() } == state::owner_uid()?,
        "Wave requires the configured unprivileged owner"
    );
    let host = if cfg!(all(target_os = "macos", target_arch = "aarch64")) {
        Host::Renekton
    } else if cfg!(all(target_os = "linux", target_arch = "x86_64")) {
        Host::Jayce
    } else if cfg!(all(target_os = "linux", target_arch = "aarch64")) {
        Host::Ahri
    } else {
        anyhow::bail!("unsupported Wave platform")
    };
    let mut hostname = [0u8; 256];
    ensure!(
        unsafe { libc::gethostname(hostname.as_mut_ptr().cast(), hostname.len()) } == 0,
        "host identity unavailable"
    );
    let name = std::str::from_utf8(hostname.split(|b| *b == 0).next().unwrap_or_default())?;
    ensure!(
        name.split('.').next() == Some(host.name()),
        "Wave host identity mismatch"
    );
    Ok(host)
}

fn run(action: Action) -> Result<i32> {
    match action {
        Action::Native(args) => native::native(args),
        Action::Confirm(args) => {
            process::install_signals()?;
            native::confirm(args)
        }
        action => {
            let host = local_host()?;
            process::install_signals()?;
            match action {
                Action::Health { json } => {
                    let report = health::check(host);
                    if json {
                        println!("{}", serde_json::to_string(&report)?);
                    } else {
                        for (name, probe) in &report.checks {
                            println!("{name:10} {}", probe.summary);
                        }
                        println!("summary: {}", report.summary);
                    }
                    Ok(if report.ok() { 0 } else { 1 })
                }
                action => {
                    let paths = state::Paths::installed()?;
                    match action {
                        Action::Check { json } => source::check(&paths, host, json),
                        Action::Switch { approve_rollback } => {
                            deploy::switch(&paths, host, approve_rollback.as_deref())
                        }
                        Action::Recover { accept_manual } => {
                            presentation::begin(host, "recover");
                            recover::run(&paths, accept_manual.as_deref())
                        }
                        _ => unreachable!(),
                    }
                }
            }
        }
    }
}

fn main() {
    let cli = Cli::parse();
    presentation::enable(!matches!(
        &cli.command,
        Action::Native(_)
            | Action::Confirm(_)
            | Action::Check { json: true }
            | Action::Health { json: true }
    ));
    let internal = matches!(&cli.command, Action::Native(_) | Action::Confirm(_));
    let (event_host, stage) = match &cli.command {
        Action::Native(args) => (Some(args.host), "supervisor"),
        Action::Confirm(args) => (Some(args.host), "confirm"),
        Action::Check { .. } => (local_host().ok(), "source"),
        Action::Switch { .. } => (local_host().ok(), "deploy"),
        Action::Recover { .. } => (local_host().ok(), "recovery"),
        Action::Health { .. } => (local_host().ok(), "health"),
    };
    let result = run(cli.command);
    let code = match result {
        Ok(code) => code,
        Err(_) => {
            // Error chains can contain subprocess output, paths or private metadata.
            presentation::error(
                "Operation failed or blocked; no raw diagnostic output was retained.",
            );
            let code = if internal {
                1
            } else if process::cancelled() {
                130
            } else {
                10
            };
            if let Some(host) = event_host {
                logging::event("failed", host, None, stage, Some(code));
            }
            code
        }
    };
    std::process::exit(code);
}
