use crate::dbus::{
    LoginManagerProxyBlocking, SystemdManagerProxyBlocking, SystemdUnitProxyBlocking,
};
use anyhow::{Context, Result, bail, ensure};
use clap::Subcommand;
use serde::Serialize;
use std::io::Write;
use std::os::unix::net::UnixDatagram;
use std::path::{Path, PathBuf};
use std::process::{Command as Process, Stdio};
use std::sync::mpsc;
use std::time::Duration;
use zbus::blocking::Connection;

const UNIT: &str = "wave-caffeinate.service";
const INHIBITOR_WHO: &str = "wave-caffeinate";
const JOB_TIMEOUT: Duration = Duration::from_secs(15);
const T3_SHELL: &str = "http://127.0.0.1:3773/api/orchestration/shell";
/// Well inside the 15-minute idle timeout; each read is a 2-3 MB snapshot.
const AGENTS_POLL: Duration = Duration::from_secs(60);

#[derive(Subcommand)]
pub enum Command {
    /// Keep background tasks running: block idle sleep, allow lock and DPMS
    On,
    /// Let the session sleep again
    Off,
    Toggle,
    /// Print the service state as JSON
    Status,
    /// Print the service state as JSON now and after every change
    Watch,
    /// Hold the sleep inhibitor; run by wave-caffeinate.service
    #[command(hide = true)]
    Hold,
    /// Turn caffeinate on while T3 Code agents run; run by wave-caffeinate-agents.service
    #[command(hide = true)]
    Agents,
}

#[derive(PartialEq, Serialize)]
struct Status {
    active: bool,
    /// systemd's ActiveState, e.g. activating or failed.
    state: String,
}

impl Status {
    fn new(state: String) -> Self {
        Self {
            active: state == "active",
            state,
        }
    }
}

pub fn run(command: Command) -> Result<i32> {
    if let Command::Hold = command {
        hold()?;
    }
    let bus = Connection::session().context("session bus unavailable")?;
    let manager = SystemdManagerProxyBlocking::new(&bus)?;
    let unit = SystemdUnitProxyBlocking::builder(&bus)
        .path(manager.load_unit(UNIT)?)?
        .build()?;
    match command {
        Command::On => change_by_hand(&manager, true)?,
        Command::Off => change_by_hand(&manager, false)?,
        Command::Toggle => {
            let active = unit.active_state()? == "active";
            change_by_hand(&manager, !active)?
        }
        Command::Status => {}
        Command::Watch => {
            watch(&manager, &unit)?;
            return Ok(1);
        }
        Command::Agents => match follow_agents(&bus, &manager)? {},
        Command::Hold => unreachable!("hold never returns"),
    }
    let state = SystemdUnitProxyBlocking::builder(&bus)
        .path(manager.load_unit(UNIT)?)?
        .cache_properties(zbus::proxy::CacheProperties::No)
        .build()?
        .active_state()?;
    println!("{}", serde_json::to_string(&Status::new(state))?);
    Ok(0)
}

/// A manual change decides caffeinate until the current agent runs end.
fn change_by_hand(manager: &SystemdManagerProxyBlocking<'static>, start: bool) -> Result<()> {
    write_owner(&owner_path()?, Owner::Hand)?;
    change(manager, start)
}

/// Who decided caffeinate's state while T3 agents run. The record lives in the
/// runtime directory, so daemon restarts and a new session keep it; the daemon
/// clears it once it sees no run.
#[derive(Clone, Copy, PartialEq)]
enum Owner {
    Agents,
    Hand,
}

fn owner_path() -> Result<PathBuf> {
    let directory = std::env::var_os("XDG_RUNTIME_DIR").context("XDG_RUNTIME_DIR is not set")?;
    Ok(PathBuf::from(directory).join("wave-caffeinate-owner"))
}

fn read_owner(path: &Path) -> Result<Option<Owner>> {
    match std::fs::read_to_string(path) {
        Ok(owner) if owner == "agents" => Ok(Some(Owner::Agents)),
        Ok(_) => Ok(Some(Owner::Hand)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error).context("cannot read the caffeinate owner"),
    }
}

fn write_owner(path: &Path, owner: Owner) -> Result<()> {
    let owner = match owner {
        Owner::Agents => "agents",
        Owner::Hand => "hand",
    };
    std::fs::write(path, owner).context("cannot record the caffeinate owner")
}

/// Keeps caffeinate on while any T3 run is active, unless it was already on
/// when they began or someone changed it by hand since. Each poll derives the
/// action from the runs, the owner record and the unit, so nothing is lost
/// when this daemon or the session restarts.
fn follow_agents(
    bus: &Connection,
    manager: &SystemdManagerProxyBlocking<'static>,
) -> Result<std::convert::Infallible> {
    let owner_path = owner_path()?;
    let unit = SystemdUnitProxyBlocking::builder(bus)
        .path(manager.load_unit(UNIT)?)?
        .cache_properties(zbus::proxy::CacheProperties::No)
        .build()?;
    let mut token = None;
    loop {
        match agents_running(&mut token) {
            Ok(true) => {
                let owner = read_owner(&owner_path)?;
                // Ending the session stops caffeinate; the agents still own it after.
                if owner != Some(Owner::Hand) && unit.active_state()? != "active" {
                    // Recorded first, so a failed start is retried after a restart.
                    write_owner(&owner_path, Owner::Agents)?;
                    change(manager, true)?;
                    eprintln!("wave caffeinate: on while T3 agents run");
                }
            }
            Ok(false) => {
                if let Some(owner) = read_owner(&owner_path)? {
                    // Cleared only after the stop, so a failed one is retried.
                    if owner == Owner::Agents {
                        change(manager, false)?;
                        eprintln!("wave caffeinate: off, no T3 agent is running");
                    }
                    std::fs::remove_file(&owner_path)?;
                }
            }
            Err(error) => eprintln!("wave caffeinate: cannot read T3 runs: {error:#}"),
        }
        std::thread::sleep(AGENTS_POLL);
    }
}

/// Any thread with an active run counts, including subagents and archived threads.
fn agents_running(issued: &mut Option<String>) -> Result<bool> {
    let token = match issued {
        Some(token) => token.clone(),
        None => issued.insert(issue_t3_token()?).clone(),
    };
    let mut child = Process::new("curl")
        .args([
            "-q",
            "--silent",
            "--show-error",
            "--max-time",
            "20",
            // The token travels on stdin, never in the argument list.
            "--config",
            "-",
            "--header",
            "x-t3-orchestration-protocol: 2",
            "--write-out",
            "\n%{http_code}",
            T3_SHELL,
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .context("cannot start curl")?;
    writeln!(
        child.stdin.take().context("curl input unavailable")?,
        "header = \"Authorization: Bearer {token}\""
    )?;
    let output = child.wait_with_output()?;
    ensure!(output.status.success(), "T3 Code is unreachable");
    let split = output.stdout.iter().rposition(|&byte| byte == b'\n');
    let (body, status) = output
        .stdout
        .split_at(split.context("curl printed no status")?);
    match &status[1..] {
        b"200" => {}
        b"401" => {
            // Expired or revoked; the next poll issues a new one.
            *issued = None;
            bail!("T3 Code rejected the token");
        }
        other => bail!("T3 Code answered {}", String::from_utf8_lossy(other)),
    }
    let shell: serde_json::Value = serde_json::from_slice(body).context("unreadable T3 shell")?;
    let threads = shell["threads"]
        .as_array()
        .context("T3 shell lists no threads")?;
    Ok(threads
        .iter()
        .any(|thread| !thread["activeRunId"].is_null()))
}

/// A read-only session the server lists under this label; it expires on its own.
fn issue_t3_token() -> Result<String> {
    let output = Process::new("t3")
        .args([
            "auth",
            "session",
            "issue",
            "--scope",
            "orchestration:read",
            "--ttl",
            "1d",
            "--label",
            "wave caffeinate",
            "--token-only",
        ])
        .stderr(Stdio::inherit())
        .output()
        .context("cannot start t3")?;
    ensure!(output.status.success(), "t3 could not issue a token");
    let token = String::from_utf8(output.stdout)?.trim().to_owned();
    // Checked here because the token is spliced into curl's configuration.
    ensure!(
        !token.is_empty()
            && token
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b)),
        "t3 issued a token with unexpected characters"
    );
    Ok(token)
}

/// Starts or stops the unit and waits for systemd to finish the job.
fn change(manager: &SystemdManagerProxyBlocking<'static>, start: bool) -> Result<()> {
    // The agents daemon changes the unit repeatedly over one connection.
    match manager.subscribe() {
        Err(zbus::Error::MethodError(name, _, _))
            if name.as_str() == "org.freedesktop.systemd1.AlreadySubscribed" => {}
        result => result?,
    }
    let removed = manager.receive_job_removed()?;
    let job = if start {
        manager.start_unit(UNIT, "replace")?
    } else {
        manager.stop_unit(UNIT, "replace")?
    };
    let (finished, result) = mpsc::channel();
    std::thread::spawn(move || {
        for signal in removed {
            if let Ok(args) = signal.args()
                && args.job.as_str() == job.as_str()
            {
                let _ = finished.send(args.result.to_owned());
                return;
            }
        }
    });
    let result = result
        .recv_timeout(JOB_TIMEOUT)
        .context("systemd did not finish the caffeinate job")?;
    ensure!(
        result == "done",
        "{UNIT} {}: {result}",
        if start { "start" } else { "stop" }
    );
    Ok(())
}

fn watch(
    manager: &SystemdManagerProxyBlocking<'static>,
    unit: &SystemdUnitProxyBlocking<'static>,
) -> Result<()> {
    manager.subscribe()?;
    let changes = unit.receive_active_state_changed();
    let mut published = Status::new(unit.active_state()?);
    println!("{}", serde_json::to_string(&published)?);
    for change in changes {
        let status = Status::new(change.get()?);
        if status != published {
            println!("{}", serde_json::to_string(&status)?);
            published = status;
        }
    }
    bail!("the session bus closed")
}

/// A weak sleep lock still lets root hibernate on a critical battery.
fn hold() -> Result<()> {
    let bus = Connection::system().context("system bus unavailable")?;
    let _inhibitor = LoginManagerProxyBlocking::new(&bus)?
        .inhibit(
            "sleep",
            INHIBITOR_WHO,
            "Keep background tasks running",
            "block-weak",
        )
        .context("logind refused the sleep inhibitor")?;
    notify_ready()?;
    loop {
        std::thread::park();
    }
}

fn notify_ready() -> Result<()> {
    let path = std::env::var("NOTIFY_SOCKET").context("NOTIFY_SOCKET is not set")?;
    let socket = UnixDatagram::unbound()?;
    if let Some(name) = path.strip_prefix('@') {
        use std::os::linux::net::SocketAddrExt;
        let address = std::os::unix::net::SocketAddr::from_abstract_name(name)?;
        socket.send_to_addr(b"READY=1", &address)?;
    } else {
        socket.send_to(b"READY=1", &path)?;
    }
    Ok(())
}
