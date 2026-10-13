use anyhow::{Context, Result, bail, ensure};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::sync::mpsc::Sender;
use std::time::Duration;
use zbus::blocking::Connection;

use crate::dbus::SystemdManagerProxyBlocking;

const REQUEST_TIMEOUT: Duration = Duration::from_secs(5);
const RECONNECT_DELAY: Duration = Duration::from_secs(1);

#[derive(Clone, Debug, Deserialize)]
pub struct Monitor {
    pub name: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub focused: bool,
    #[serde(rename = "dpmsStatus", default)]
    pub dpms_status: bool,
    #[serde(rename = "activeWorkspace")]
    pub active_workspace: WorkspaceRef,
}

#[derive(Clone, Debug, Deserialize)]
pub struct WorkspaceRef {
    pub id: i64,
}

#[derive(Clone, Debug, Deserialize)]
pub struct Workspace {
    pub id: i64,
    pub monitor: String,
    #[serde(default)]
    pub windows: u32,
    #[serde(default)]
    pub ispersistent: bool,
}

impl Workspace {
    /// Regular workspaces that hold windows or are declared persistent; the
    /// reconciler migrates and remembers only these.
    pub fn managed(&self) -> bool {
        self.id > 0 && (self.ispersistent || self.windows > 0)
    }
}

pub enum Event {
    Connected(Hyprland),
    Disconnected,
    Line(String),
}

/// The Hyprland instance this session runs, addressed through its sockets.
#[derive(Clone)]
pub struct Hyprland {
    pub signature: String,
    runtime: PathBuf,
    directory: PathBuf,
}

impl Hyprland {
    pub fn from_environment(runtime: &std::path::Path) -> Result<Self> {
        let signature = std::env::var("HYPRLAND_INSTANCE_SIGNATURE")
            .context("HYPRLAND_INSTANCE_SIGNATURE is not set")?;
        Self::for_signature(runtime, signature)
    }

    fn for_signature(runtime: &std::path::Path, signature: String) -> Result<Self> {
        ensure!(
            !signature.is_empty()
                && signature != "."
                && signature != ".."
                && !signature.contains('/'),
            "invalid HYPRLAND_INSTANCE_SIGNATURE"
        );
        Ok(Self {
            runtime: runtime.to_owned(),
            directory: runtime.join("hypr").join(&signature),
            signature,
        })
    }

    fn from_activation_environment(runtime: &std::path::Path) -> Result<Self> {
        let connection = Connection::session()?;
        let manager = SystemdManagerProxyBlocking::new(&connection)?;
        let signature = manager
            .environment()?
            .into_iter()
            .find_map(|entry| {
                entry
                    .strip_prefix("HYPRLAND_INSTANCE_SIGNATURE=")
                    .map(str::to_owned)
            })
            .context("Hyprland is absent from the activation environment")?;
        Self::for_signature(runtime, signature)
    }

    fn request(&self, body: &str) -> Result<String> {
        let mut stream = UnixStream::connect(self.directory.join(".socket.sock"))
            .context("Hyprland request socket unavailable")?;
        stream.set_read_timeout(Some(REQUEST_TIMEOUT))?;
        stream.set_write_timeout(Some(REQUEST_TIMEOUT))?;
        stream.write_all(body.as_bytes())?;
        let mut reply = String::new();
        stream
            .read_to_string(&mut reply)
            .with_context(|| format!("Hyprland did not answer {body:?}"))?;
        Ok(reply)
    }

    fn query<T: DeserializeOwned>(&self, what: &str) -> Result<T> {
        let reply = self.request(&format!("j/{what}"))?;
        serde_json::from_str(&reply).with_context(|| format!("invalid Hyprland {what} reply"))
    }

    /// Enabled monitors only; a disabled output is absent.
    pub fn monitors(&self) -> Result<Vec<Monitor>> {
        let mut monitors: Vec<Monitor> = self.query("monitors")?;
        // Hyprland's emergency output is not a usable external screen.
        monitors.retain(|monitor| monitor.name != "FALLBACK");
        Ok(monitors)
    }

    pub fn workspaces(&self) -> Result<Vec<Workspace>> {
        self.query("workspaces")
    }

    fn expect_ok(&self, body: &str) -> Result<()> {
        let reply = self.request(body)?;
        if reply.trim() != "ok" {
            bail!("Hyprland rejected {body:?}: {}", reply.trim());
        }
        Ok(())
    }

    pub fn dispatch(&self, lua: &str) -> Result<()> {
        self.expect_ok(&format!("dispatch {lua}"))
    }

    pub fn eval(&self, lua: &str) -> Result<()> {
        self.expect_ok(&format!("eval {lua}"))
    }

    /// Streams socket2 lines forever, reconnecting while Hyprland restarts.
    pub fn follow_events(&self, events: Sender<Event>) {
        let mut instance = self.clone();
        loop {
            if let Ok(stream) = UnixStream::connect(instance.directory.join(".socket2.sock")) {
                if events.send(Event::Connected(instance.clone())).is_err() {
                    return;
                }
                let mut reader = BufReader::new(stream);
                let mut line = Vec::new();
                loop {
                    line.clear();
                    match reader.read_until(b'\n', &mut line) {
                        Ok(0) | Err(_) => break,
                        Ok(_) => {
                            let text = String::from_utf8_lossy(&line).trim_end().to_owned();
                            if !text.is_empty() && events.send(Event::Line(text)).is_err() {
                                return;
                            }
                        }
                    }
                }
                if events.send(Event::Disconnected).is_err() {
                    return;
                }
            }
            std::thread::sleep(RECONNECT_DELAY);
            // start-hyprland can replace the compositor without restarting our
            // service. Its new sockets are exported to the user manager.
            if let Ok(current) = Self::from_activation_environment(&self.runtime) {
                instance = current;
            }
        }
    }
}

/// The socket2 events the reconciler acts on. Workspace names and monitor
/// descriptions may contain commas; IDs and connector names cannot.
#[derive(Debug, PartialEq)]
pub enum Notice<'a> {
    WorkspaceMoved { id: i64, monitor: &'a str },
    WorkspaceDestroyed { id: i64 },
    MonitorRemoved { name: &'a str },
    MonitorAdded { name: &'a str, description: &'a str },
    ConfigReloaded,
    ActiveChanged,
}

pub fn parse_event(line: &str) -> Option<Notice<'_>> {
    let (event, payload) = line.split_once(">>")?;
    let leading_id = || payload.split(',').next()?.parse().ok();
    match event {
        "moveworkspacev2" => Some(Notice::WorkspaceMoved {
            id: leading_id()?,
            monitor: payload.rsplit_once(',')?.1,
        }),
        "destroyworkspacev2" => Some(Notice::WorkspaceDestroyed { id: leading_id()? }),
        "monitorremovedv2" => Some(Notice::MonitorRemoved {
            name: payload.split(',').nth(1)?,
        }),
        "monitoraddedv2" => {
            let mut parts = payload.splitn(3, ',');
            parts.next()?;
            Some(Notice::MonitorAdded {
                name: parts.next()?,
                description: parts.next().unwrap_or_default(),
            })
        }
        "configreloaded" => Some(Notice::ConfigReloaded),
        "workspacev2" | "focusedmonv2" | "createworkspacev2" => Some(Notice::ActiveChanged),
        _ => None,
    }
}
