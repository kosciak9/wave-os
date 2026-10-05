mod queries;
mod server;
mod session;
mod slack;
mod store;
mod sync;

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use std::{net::SocketAddr, path::PathBuf, time::Duration};

#[derive(Parser)]
#[command(version, about = "Independent local Slack mirror with read-only MCP")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    Serve {
        #[arg(long)]
        database: PathBuf,
        #[arg(long, required_unless_present = "offline")]
        session_file: Option<PathBuf>,
        #[arg(long)]
        mcp_token_file: PathBuf,
        #[arg(long, default_value = "127.0.0.1:19440")]
        listen: SocketAddr,
        /// Serve the existing archive without connecting to Slack.
        #[arg(long)]
        offline: bool,
    },
    /// Capture the chosen workspace from a locally signed-in Chrome CDP session.
    CaptureSession {
        #[arg(long)]
        workspace: String,
        #[arg(long, default_value = "http://127.0.0.1:9333")]
        cdp_url: String,
        #[arg(long)]
        output: PathBuf,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    // The service creates a private archive even outside its container wrapper.
    unsafe { libc::umask(0o077) };
    tracing_subscriber::fmt()
        .with_env_filter("wave_slack_mirror=info")
        .with_target(false)
        .init();
    match Cli::parse().command {
        Command::CaptureSession {
            workspace,
            cdp_url,
            output,
        } => session::capture(&workspace, &cdp_url, &output).await,
        Command::Serve {
            database,
            session_file,
            mcp_token_file,
            listen,
            offline,
        } => {
            let token = session::load_mcp_token(&mcp_token_file)?;
            let store = store::Store::open(&database).context("cannot open mirror archive")?;
            store.set_meta("rtm_state", if offline { "offline" } else { "starting" })?;
            store.set_meta("offline", if offline { "true" } else { "false" })?;
            store.set_meta("sync_state", if offline { "offline" } else { "starting" })?;
            let engine = if offline {
                store.set_meta("auth_state", "offline")?;
                None
            } else {
                let client = slack::SlackClient::new(
                    session_file.context("Slack synchronization requires --session-file")?,
                )?;
                let archive = store.clone();
                Some(tokio::spawn(async move {
                    loop {
                        if sync::run(archive.clone(), client.clone()).await.is_err() {
                            let _ = archive
                                .set_meta("engine_error", "synchronization stopped; retrying");
                            tracing::warn!(
                                "synchronization stopped; retrying without discarding progress"
                            );
                        }
                        tokio::time::sleep(Duration::from_secs(30)).await;
                    }
                }))
            };
            let result = server::serve(store, token, listen).await;
            if let Some(engine) = engine {
                engine.abort();
            }
            result
        }
    }
}
