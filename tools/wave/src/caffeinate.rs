use crate::dbus::{
    LoginManagerProxyBlocking, SystemdManagerProxyBlocking, SystemdUnitProxyBlocking,
};
use anyhow::{Context, Result, bail, ensure};
use clap::Subcommand;
use serde::Serialize;
use std::os::unix::net::UnixDatagram;
use std::sync::mpsc;
use std::time::Duration;
use zbus::blocking::Connection;

const UNIT: &str = "wave-caffeinate.service";
/// The power profile policy recognises caffeinate by this inhibitor owner.
const INHIBITOR_WHO: &str = "wave-caffeinate";
const JOB_TIMEOUT: Duration = Duration::from_secs(15);

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
        Command::On => change(&manager, true)?,
        Command::Off => change(&manager, false)?,
        Command::Toggle => {
            let active = unit.active_state()? == "active";
            change(&manager, !active)?
        }
        Command::Status => {}
        Command::Watch => {
            watch(&manager, &unit)?;
            return Ok(1);
        }
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

/// Starts or stops the unit and waits for systemd to finish the job.
fn change(manager: &SystemdManagerProxyBlocking<'static>, start: bool) -> Result<()> {
    manager.subscribe()?;
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
