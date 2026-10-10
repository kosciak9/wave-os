mod hyprland;
mod logind;
mod ownership;
mod reconciler;

use anyhow::{Context, Result, bail};
use clap::{Subcommand, ValueEnum};
use hyprland::Hyprland;
use logind::Logind;
use ownership::{Ownership, State};
use reconciler::{Action, Reconciler, Status};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::time::Duration;

const CLIENT_WRITE_TIMEOUT: Duration = Duration::from_secs(2);
/// Covers a full convergence: blackout, workspace moves and a config reload.
const CLIENT_REPLY_TIMEOUT: Duration = Duration::from_secs(30);
const WATCHER_WRITE_TIMEOUT: Duration = Duration::from_millis(200);
const IDLE_WAIT: Duration = Duration::from_secs(3600);

#[derive(Subcommand)]
pub enum Command {
    /// Run the session display daemon (lid, outputs, workspaces, sleep)
    Daemon,
    /// Tell the daemon about a session event
    Notify {
        #[arg(value_enum)]
        event: NotifyEvent,
    },
    /// Keep the laptop screen off as if the lid were closed, while an
    /// external display is connected
    LidOverride {
        #[arg(value_enum)]
        mode: OverrideMode,
    },
}

#[derive(Clone, Copy, ValueEnum)]
pub enum NotifyEvent {
    LidClose,
    LidOpen,
    IdleStart,
    IdleEnd,
    DisplayOn,
}

#[derive(Clone, Copy, ValueEnum)]
pub enum OverrideMode {
    On,
    Off,
    Toggle,
    /// Print the current state as JSON
    Status,
    /// Print the state as JSON now and after every change
    Watch,
}

pub fn run(command: Command) -> Result<i32> {
    let paths = Paths::from_environment()?;
    match command {
        Command::Daemon => daemon(&paths).map(|()| 0),
        Command::Notify { event } => {
            let name = NotifyEvent::to_possible_value(&event)
                .expect("events have names")
                .get_name()
                .to_owned();
            request(&paths, &format!("notify {name}")).map(|_| 0)
        }
        Command::LidOverride { mode } => {
            let line = match mode {
                OverrideMode::On => "lid-override on",
                OverrideMode::Off => "lid-override off",
                OverrideMode::Toggle => "lid-override toggle",
                OverrideMode::Status => "status",
                OverrideMode::Watch => return watch(&paths).map(|()| 1),
            };
            println!("{}", request(&paths, line)?);
            Ok(0)
        }
    }
}

struct Paths {
    runtime: PathBuf,
    directory: PathBuf,
}

impl Paths {
    fn from_environment() -> Result<Self> {
        let runtime = PathBuf::from(
            std::env::var_os("XDG_RUNTIME_DIR").context("XDG_RUNTIME_DIR is not set")?,
        );
        Ok(Self {
            directory: runtime.join("wave-display"),
            runtime,
        })
    }

    fn control(&self) -> PathBuf {
        self.directory.join("control.sock")
    }

    fn state(&self) -> PathBuf {
        self.directory.join("state.json")
    }

    /// Read by Hyprland's config on every load; see hosts/jayce/desktop/hyprland.lua.
    fn internal_off(&self) -> PathBuf {
        self.directory.join("internal-off")
    }
}

fn connect(paths: &Paths, line: &str) -> Result<UnixStream> {
    let mut stream =
        UnixStream::connect(paths.control()).context("the wave display daemon is not running")?;
    stream.set_write_timeout(Some(CLIENT_WRITE_TIMEOUT))?;
    stream.set_read_timeout(Some(CLIENT_REPLY_TIMEOUT))?;
    stream.write_all(format!("{line}\n").as_bytes())?;
    Ok(stream)
}

fn request(paths: &Paths, line: &str) -> Result<String> {
    let mut reply = String::new();
    BufReader::new(connect(paths, line)?)
        .read_line(&mut reply)
        .context("the wave display daemon did not answer")?;
    let reply = reply.trim_end();
    if let Some(error) = reply.strip_prefix("error: ") {
        bail!("{error}");
    }
    if reply.is_empty() {
        bail!("the wave display daemon closed the connection");
    }
    Ok(reply.to_owned())
}

/// Returns once the daemon goes away, so the caller can resubscribe.
fn watch(paths: &Paths) -> Result<()> {
    let stream = connect(paths, "watch")?;
    stream.set_read_timeout(None)?;
    let mut stdout = std::io::stdout();
    for line in BufReader::new(stream).lines() {
        writeln!(stdout, "{}", line?)?;
        stdout.flush()?;
    }
    Ok(())
}

enum Event {
    Hyprland(hyprland::Event),
    Logind(logind::Event),
    Request(String, Sender<String>),
    Watch(UnixStream),
}

impl From<logind::Event> for Event {
    fn from(event: logind::Event) -> Self {
        Self::Logind(event)
    }
}

fn load_state(path: &Path, signature: &str) -> State {
    let mut state: State = fs::read(path)
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default();
    if state.lid_override.as_deref() != Some(signature) {
        state.lid_override = None;
    }
    state
}

fn save_state(path: &Path, state: &State) -> Result<()> {
    let temporary = path.with_extension("json.tmp");
    fs::write(&temporary, serde_json::to_vec(state)?)?;
    fs::rename(&temporary, path)?;
    Ok(())
}

fn bind_control(paths: &Paths) -> Result<UnixListener> {
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&paths.directory)?;
    let control = paths.control();
    if UnixStream::connect(&control).is_ok() {
        bail!("another wave display daemon is running");
    }
    match fs::remove_file(&control) {
        Err(error) if error.kind() != std::io::ErrorKind::NotFound => return Err(error.into()),
        _ => {}
    }
    let listener = UnixListener::bind(&control)?;
    fs::set_permissions(&control, fs::Permissions::from_mode(0o600))?;
    Ok(listener)
}

fn serve_control(listener: UnixListener, events: Sender<Event>) {
    for stream in listener.incoming().flatten() {
        let events = events.clone();
        std::thread::spawn(move || {
            let _ = stream.set_read_timeout(Some(CLIENT_WRITE_TIMEOUT));
            let mut line = String::new();
            let Ok(reader) = stream.try_clone() else {
                return;
            };
            if BufReader::new(reader).read_line(&mut line).is_err() {
                return;
            }
            let line = line.trim().to_owned();
            if line == "watch" {
                let _ = events.send(Event::Watch(stream));
                return;
            }
            let (reply_to, reply) = mpsc::channel();
            if events.send(Event::Request(line, reply_to)).is_err() {
                return;
            }
            if let Ok(answer) = reply.recv_timeout(CLIENT_REPLY_TIMEOUT) {
                let mut stream = stream;
                let _ = stream.write_all(format!("{answer}\n").as_bytes());
            }
        });
    }
}

fn status_line(status: Status) -> String {
    serde_json::to_string(&status).expect("status serializes")
}

fn answer(reconciler: &mut Reconciler, line: &str) -> String {
    let result = match line.split_once(' ') {
        Some(("notify", name)) => match Action::parse(name) {
            Some(action) => {
                reconciler.action(action);
                Ok(reconciler.status())
            }
            None => Err(format!("unknown event {name:?}")),
        },
        Some(("lid-override", mode)) => match mode {
            "on" => reconciler.set_override(true),
            "off" => reconciler.set_override(false),
            "toggle" => {
                let active = reconciler.status().active;
                reconciler.set_override(!active)
            }
            _ => Err(format!("unknown lid override mode {mode:?}")),
        },
        None if line == "status" => Ok(reconciler.status()),
        _ => Err(format!("unknown request {line:?}")),
    };
    match result {
        Ok(status) => status_line(status),
        Err(error) => format!("error: {error}"),
    }
}

fn daemon(paths: &Paths) -> Result<()> {
    let listener = bind_control(paths)?;
    let hyprland = Hyprland::from_environment(&paths.runtime)?;
    let logind = Logind::connect()?;
    let _lid_switch = logind.inhibit_lid_switch()?;

    let (events, incoming) = mpsc::channel();
    logind.follow(events.clone())?;
    {
        let events = events.clone();
        std::thread::spawn(move || serve_control(listener, events));
    }
    {
        let hyprland = hyprland.clone();
        let (forward, hyprland_events) = mpsc::channel();
        std::thread::spawn(move || hyprland.follow_events(forward));
        let events = events.clone();
        std::thread::spawn(move || {
            for event in hyprland_events {
                if events.send(Event::Hyprland(event)).is_err() {
                    return;
                }
            }
        });
    }
    drop(events);

    let state = load_state(&paths.state(), &hyprland.signature);
    let mut reconciler = Reconciler::new(
        hyprland,
        logind,
        Ownership::new(state),
        paths.internal_off(),
    );
    let mut watchers: Vec<UnixStream> = Vec::new();
    let mut published: Option<Status> = None;
    let mut next_due = None;

    loop {
        let wait = next_due
            .map(|due: std::time::Instant| due.saturating_duration_since(std::time::Instant::now()))
            .unwrap_or(IDLE_WAIT);
        match incoming.recv_timeout(wait) {
            Ok(Event::Hyprland(hyprland::Event::Connected)) => reconciler.hyprland_connected(),
            Ok(Event::Hyprland(hyprland::Event::Disconnected)) => {
                reconciler.hyprland_disconnected()
            }
            Ok(Event::Hyprland(hyprland::Event::Line(line))) => {
                if let Some(notice) = hyprland::parse_event(&line) {
                    reconciler.hyprland_notice(notice);
                }
            }
            Ok(Event::Logind(logind::Event::Changed)) => reconciler.logind_changed(),
            Ok(Event::Logind(logind::Event::Resumed)) => reconciler.resumed(),
            Ok(Event::Logind(logind::Event::Lost(reason))) => bail!("{reason}"),
            Ok(Event::Request(line, reply_to)) => {
                let _ = reply_to.send(answer(&mut reconciler, &line));
            }
            Ok(Event::Watch(mut stream)) => {
                let _ = stream.set_write_timeout(Some(WATCHER_WRITE_TIMEOUT));
                let line = format!("{}\n", status_line(reconciler.status()));
                if stream.write_all(line.as_bytes()).is_ok() {
                    watchers.push(stream);
                }
            }
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => bail!("all event sources stopped"),
        }
        next_due = reconciler.tick();
        if let Err(error) = save_state(&paths.state(), &reconciler.ownership.state) {
            eprintln!("wave display: cannot save state: {error:#}");
        }
        let status = reconciler.status();
        if published != Some(status) {
            published = Some(status);
            let line = format!("{}\n", status_line(status));
            watchers.retain_mut(|watcher| watcher.write_all(line.as_bytes()).is_ok());
        }
    }
}
