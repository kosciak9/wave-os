mod autodeploy;
#[cfg(target_os = "linux")]
mod caffeinate;
mod dashboard;
#[cfg(target_os = "linux")]
mod dbus;
#[cfg(target_os = "linux")]
mod display;
mod github;
mod health;
mod logging;
mod model;
mod presentation;
mod process;
mod remote;
mod source;
mod state;
mod switch;

use anyhow::{Result, ensure};
use clap::{CommandFactory, Parser, Subcommand};
use std::path::PathBuf;

#[derive(Parser)]
#[command(
    name = "wave",
    version,
    about = "wave-os source, switches and deployments"
)]
struct Cli {
    #[command(subcommand)]
    command: Action,
}

#[derive(Subcommand)]
enum Action {
    /// Fetch main and detect updates that passed CI; exit 0=current, 1=available,
    /// 2=unknown revision, 3=CI running on main, 4=CI failed on main
    Check {
        #[arg(long)]
        json: bool,
    },
    /// Build latest main for this host, activate it, and roll back if it is unhealthy
    Switch {
        /// Allow switching a deploy target in place, without the remote reachability check
        #[arg(long)]
        local: bool,
    },
    /// Deploy a node of the flake from latest main through deploy-rs over SSH
    Deploy {
        #[arg(value_name = "NODE")]
        node: String,
    },
    /// Deploy latest main once CI passes: this host first, the nodes on a later run
    Autodeploy {
        #[arg(value_name = "NODE")]
        nodes: Vec<String>,
    },
    /// Health checks declared by the active system
    Health {
        #[arg(long)]
        json: bool,
        /// Wait until consecutive checks pass; exit 1 at the deadline
        #[arg(long)]
        wait: bool,
        #[arg(long, value_name = "PATH", default_value = health::MANIFEST)]
        manifest: PathBuf,
        #[arg(long, value_name = "SECONDS", default_value_t = 120)]
        timeout: u64,
        #[arg(long, default_value_t = 3)]
        streak: u32,
    },
    /// Register this host's apps on the wave.exposed dashboard
    Dashboard {
        #[command(subcommand)]
        action: DashboardAction,
    },
    /// Print the shell completion script
    #[command(hide = true)]
    Completion { shell: clap_complete::Shell },
    /// Keep background tasks running without preventing lock or DPMS
    #[cfg(target_os = "linux")]
    Caffeinate {
        #[command(subcommand)]
        command: caffeinate::Command,
    },
    /// Session display policy: lid, outputs, workspaces and sleep
    #[cfg(target_os = "linux")]
    Display {
        #[command(subcommand)]
        command: display::Command,
    },
}

#[derive(Subcommand)]
enum DashboardAction {
    /// Expose a local port as an app; prints its URL
    Add {
        project: String,
        branch: String,
        #[arg(long)]
        port: u16,
    },
    /// Unregister an app; succeeds when it was not registered
    Remove { project: String, branch: String },
}

/// The short hostname names this host's configuration in the flake.
fn hostname() -> Result<String> {
    let mut buffer = [0u8; 256];
    ensure!(
        unsafe { libc::gethostname(buffer.as_mut_ptr().cast(), buffer.len()) } == 0,
        "hostname unavailable"
    );
    let name = std::str::from_utf8(buffer.split(|b| *b == 0).next().unwrap_or_default())?;
    let name = name.split('.').next().unwrap_or_default();
    ensure!(
        !name.is_empty() && name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-'),
        "invalid hostname"
    );
    Ok(name.to_owned())
}

fn owner_paths() -> Result<state::Paths> {
    ensure!(
        unsafe { libc::geteuid() } == state::owner_uid()?,
        "run wave-os as its owner, not root"
    );
    state::Paths::installed()
}

fn run(action: Action) -> Result<i32> {
    match action {
        Action::Health {
            json,
            wait,
            manifest,
            timeout,
            streak,
        } => {
            if wait {
                let healthy =
                    health::wait(&manifest, std::time::Duration::from_secs(timeout), streak);
                return Ok(if healthy { 0 } else { 1 });
            }
            let report = health::check_manifest(&manifest);
            if json {
                println!("{}", serde_json::to_string(&report)?);
            } else {
                health::print(&report);
            }
            Ok(if report.ok() { 0 } else { 1 })
        }
        Action::Check { json } => {
            presentation::enable(!json);
            source::check(&owner_paths()?, &hostname()?, json)
        }
        Action::Switch { local } => switch::switch(&owner_paths()?, &hostname()?, local),
        Action::Deploy { node } => remote::deploy(&owner_paths()?, &node),
        Action::Autodeploy { nodes } => autodeploy::run(&owner_paths()?, &hostname()?, &nodes),
        Action::Completion { shell } => {
            clap_complete::generate(shell, &mut Cli::command(), "wave", &mut std::io::stdout());
            Ok(0)
        }
        Action::Dashboard { action } => match action {
            DashboardAction::Add {
                project,
                branch,
                port,
            } => dashboard::add(&project, &branch, port),
            DashboardAction::Remove { project, branch } => dashboard::remove(&project, &branch),
        },
        #[cfg(target_os = "linux")]
        Action::Caffeinate { command } => caffeinate::run(command),
        #[cfg(target_os = "linux")]
        Action::Display { command } => display::run(command),
    }
}

fn main() {
    let code = run(Cli::parse().command).unwrap_or_else(|error| {
        presentation::enable(true);
        presentation::error(&format!("{error:#}"));
        10
    });
    std::process::exit(code);
}
