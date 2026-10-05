use crate::model::{Host, sha40};
use std::sync::atomic::{AtomicBool, Ordering};

static UNAVAILABLE_REPORTED: AtomicBool = AtomicBool::new(false);

pub fn event(name: &str, host: Host, commit: Option<&str>, stage: &str, code: Option<i32>) {
    // Unknown labels are never forwarded: callers cannot turn this into a raw log sink.
    let name = if EVENTS.contains(&name) {
        name
    } else {
        "event"
    };
    let stage = if STAGES.contains(&stage) {
        stage
    } else {
        "unknown"
    };
    let revision = commit.filter(|value| sha40(value));
    let mut message = format!("wave: {name} host={} stage={stage}", host.name());
    if let Some(revision) = revision {
        message.push_str(&format!(" revision={revision}"));
    }
    if let Some(code) = code {
        message.push_str(&format!(" exit={code}"));
    }
    if !system_event(name, host, revision, stage, code, &message)
        && !UNAVAILABLE_REPORTED.swap(true, Ordering::Relaxed)
    {
        crate::presentation::warning("System logging is unavailable");
    }
}

const EVENTS: &[&str] = &[
    "start",
    "complete",
    "success",
    "failed",
    "blocked",
    "health_passed",
    "health_failed",
    "deploy_started",
    "deploy_finished",
    "confirmed",
    "restored",
    "reconciled",
    "heartbeat",
    "activation_started",
    "activation_finished",
];
const STAGES: &[&str] = &[
    "source",
    "preflight",
    "validation",
    "prepare",
    "build",
    "deploy",
    "health",
    "confirm",
    "rollback",
    "recovery",
    "status",
    "supervisor",
];

#[cfg(target_os = "linux")]
fn system_event(
    name: &str,
    host: Host,
    revision: Option<&str>,
    stage: &str,
    code: Option<i32>,
    message: &str,
) -> bool {
    use std::os::unix::net::UnixDatagram;
    let mut fields = format!(
        "MESSAGE={message}\nSYSLOG_IDENTIFIER=wave\nPRIORITY=5\nWAVE_EVENT={name}\nWAVE_HOST={}\nWAVE_STAGE={stage}\n",
        host.name()
    );
    if let Some(revision) = revision {
        fields.push_str(&format!("WAVE_REVISION={revision}\n"));
    }
    if let Some(code) = code {
        fields.push_str(&format!("WAVE_EXIT={code}\n"));
    }
    let Ok(socket) = UnixDatagram::unbound() else {
        return false;
    };
    if socket.set_nonblocking(true).is_err() {
        return false;
    }
    socket
        .send_to(fields.as_bytes(), "/run/systemd/journal/socket")
        .is_ok()
}

#[cfg(target_os = "macos")]
fn system_event(
    _name: &str,
    _host: Host,
    _revision: Option<&str>,
    _stage: &str,
    _code: Option<i32>,
    message: &str,
) -> bool {
    unsafe extern "C" {
        fn wave_os_log(message: *const libc::c_char) -> libc::c_int;
    }
    let Ok(message) = std::ffi::CString::new(message) else {
        return false;
    };
    unsafe { wave_os_log(message.as_ptr()) != 0 }
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn system_event(
    _name: &str,
    _host: Host,
    _revision: Option<&str>,
    _stage: &str,
    _code: Option<i32>,
    _message: &str,
) -> bool {
    false
}
