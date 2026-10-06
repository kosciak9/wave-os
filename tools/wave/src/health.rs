use crate::model::Host;
use crate::process;
use serde::Serialize;
use std::collections::BTreeMap;
use std::net::{IpAddr, SocketAddr, TcpStream};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const BUDGET: Duration = Duration::from_secs(4);
const HTTPS: [&str; 2] = [
    "https://www.cloudflare.com/cdn-cgi/trace",
    "https://www.google.com/generate_204",
];

#[derive(Debug, Serialize)]
pub struct Health {
    pub ok: bool,
    pub summary: &'static str,
    pub checks: BTreeMap<&'static str, Probe>,
}

impl Health {
    pub fn ok(&self) -> bool {
        self.ok
    }
}

#[derive(Debug, Serialize)]
pub struct Probe {
    pub ok: bool,
    pub summary: &'static str,
}

fn result(ok: bool) -> Probe {
    Probe {
        ok,
        summary: if ok { "healthy" } else { "unhealthy" },
    }
}

fn tool(name: &str) -> String {
    let active = format!("/run/current-system/sw/bin/{name}");
    if std::path::Path::new(&active).is_file() {
        active
    } else {
        name.to_owned()
    }
}

fn capture(binary: &str, args: &[&str], deadline: Instant) -> Option<Vec<u8>> {
    let remaining = deadline.checked_duration_since(Instant::now())?;
    let output = process::capture_uncancelled(
        Command::new(binary).args(args).stdin(Stdio::null()),
        remaining,
    )
    .ok()?;
    (output.code == 0 && !output.interrupted && !output.timed_out).then_some(output.stdout)
}

fn network(host: Host, deadline: Instant) -> bool {
    match host {
        Host::Renekton => {
            let first = deadline.min(Instant::now() + Duration::from_millis(1500));
            capture("/sbin/route", &["-n", "get", "default"], first).is_some()
                || capture("/sbin/route", &["-n", "get", "-inet6", "default"], deadline).is_some()
        }
        Host::Jayce | Host::Ahri => {
            let ip = tool("ip");
            let first = deadline.min(Instant::now() + Duration::from_millis(1500));
            let has_route = |bytes: Vec<u8>| !bytes.iter().all(u8::is_ascii_whitespace);
            capture(&ip, &["-4", "route", "show", "default"], first).is_some_and(has_route)
                || capture(&ip, &["-6", "route", "show", "default"], deadline)
                    .is_some_and(has_route)
        }
    }
}

fn dns(host: Host, deadline: Instant) -> bool {
    match host {
        Host::Renekton => capture(
            "/usr/bin/dscacheutil",
            &["-q", "host", "-a", "name", "example.com"],
            deadline,
        )
        .is_some_and(|bytes| {
            String::from_utf8_lossy(&bytes).lines().any(|line| {
                line.split_once(':').is_some_and(|(key, value)| {
                    matches!(key.trim(), "ip_address" | "ipv6_address")
                        && value.trim().parse::<IpAddr>().is_ok()
                })
            })
        }),
        Host::Jayce | Host::Ahri => capture(&tool("getent"), &["ahosts", "example.com"], deadline)
            .is_some_and(|bytes| {
                String::from_utf8_lossy(&bytes).lines().any(|line| {
                    line.split_whitespace()
                        .next()
                        .is_some_and(|address| address.parse::<IpAddr>().is_ok())
                })
            }),
    }
}

fn https(url: &str, deadline: Instant) -> bool {
    capture(
        &tool("curl"),
        &[
            "-q",
            "-sS",
            "-f",
            "--connect-timeout",
            "3",
            "--max-time",
            "3",
            "--output",
            "/dev/null",
            "--write-out",
            "%{http_code}",
            "--proto",
            "=https",
            url,
        ],
        deadline,
    )
    .is_some_and(|bytes| {
        std::str::from_utf8(&bytes)
            .ok()
            .and_then(|text| text.trim().parse::<u16>().ok())
            .is_some_and(|status| (200..400).contains(&status))
    })
}

fn tailscale(deadline: Instant) -> bool {
    capture(&tool("tailscale"), &["status", "--json"], deadline).is_some_and(|bytes| {
        serde_json::from_slice::<serde_json::Value>(&bytes)
            .ok()
            .is_some_and(|value| {
                value.get("BackendState").and_then(|v| v.as_str()) == Some("Running")
                    && value
                        .get("Health")
                        .is_none_or(|warnings| warnings.as_array().is_some_and(Vec::is_empty))
            })
    })
}

fn openclaw(path: &str, deadline: Instant) -> bool {
    let url = format!("http://127.0.0.1:18789{path}");
    capture(
        &tool("curl"),
        &[
            "-q",
            "-sS",
            "--noproxy",
            "*",
            "--connect-timeout",
            "3",
            "--max-time",
            "3",
            "--max-filesize",
            "65536",
            "--write-out",
            "\nWAVE_STATUS:%{http_code}",
            &url,
        ],
        deadline,
    )
    .is_some_and(|bytes| {
        let Ok(text) = std::str::from_utf8(&bytes) else {
            return false;
        };
        let Some((body, status)) = text.rsplit_once("\nWAVE_STATUS:") else {
            return false;
        };
        body.len() <= 65536
            && status
                .trim()
                .parse::<u16>()
                .ok()
                .is_some_and(|status| (200..300).contains(&status))
            && serde_json::from_str::<serde_json::Value>(body)
                .ok()
                .is_some_and(|value| value.get("ok").and_then(|v| v.as_bool()) == Some(true))
    })
}

fn ssh(deadline: Instant) -> bool {
    let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
        return false;
    };
    let address = SocketAddr::from(([127, 0, 0, 1], 22));
    let Ok(mut stream) =
        TcpStream::connect_timeout(&address, remaining.min(Duration::from_millis(500)))
    else {
        return false;
    };
    // Reachability includes an SSH identification, not merely another TCP listener.
    let mut banner = Vec::new();
    use std::io::Read;
    while Instant::now() < deadline && banner.len() < 1024 {
        let _ = stream.set_read_timeout(Some(Duration::from_millis(50)));
        let mut buffer = [0; 128];
        match stream.read(&mut buffer) {
            Ok(0) => break,
            Ok(count) => {
                banner.extend_from_slice(&buffer[..count]);
                if banner
                    .split(|byte| *byte == b'\n')
                    .any(|line| line.starts_with(b"SSH-2.0-") || line.starts_with(b"SSH-1.99-"))
                {
                    return true;
                }
            }
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock
                        | std::io::ErrorKind::TimedOut
                        | std::io::ErrorKind::Interrupted
                ) =>
            {
                continue;
            }
            Err(_) => break,
        }
    }
    false
}

fn caddy(deadline: Instant) -> bool {
    capture(
        &tool("curl"),
        &[
            "-q",
            "-sS",
            "-f",
            "--noproxy",
            "*",
            "--connect-timeout",
            "1",
            "--max-time",
            "3",
            "--output",
            "/dev/null",
            "--write-out",
            "%{http_code}",
            "http://127.0.0.1:8080/healthz",
        ],
        deadline,
    )
    .is_some_and(|bytes| bytes == b"200")
}

fn usb_root(deadline: Instant) -> bool {
    let Some(bytes) = capture(
        &tool("findmnt"),
        &[
            "--json",
            "--target",
            "/",
            "--output",
            "FSTYPE,SOURCE,OPTIONS",
        ],
        deadline,
    ) else {
        return false;
    };
    let Ok(value) = serde_json::from_slice::<serde_json::Value>(&bytes) else {
        return false;
    };
    let Some(mounts) = value.get("filesystems").and_then(|value| value.as_array()) else {
        return false;
    };
    if mounts.len() != 1 {
        return false;
    }
    let mount = &mounts[0];
    if mount.get("fstype").and_then(|value| value.as_str()) != Some("btrfs") {
        return false;
    }
    let Some(options) = mount.get("options").and_then(|value| value.as_str()) else {
        return false;
    };
    if !options.split(',').any(|option| option == "rw")
        || !options.split(',').any(|option| option == "subvol=/@root")
    {
        return false;
    }
    let Some(source) = mount.get("source").and_then(|value| value.as_str()) else {
        return false;
    };
    let device = source.split('[').next().unwrap_or_default();
    if !device.starts_with("/dev/") {
        return false;
    }
    let Ok(device) = std::fs::canonicalize(device) else {
        return false;
    };
    let Some(bytes) = capture(
        &tool("lsblk"),
        &["--json", "--tree", "--output", "PATH,TYPE,TRAN,FSTYPE,UUID"],
        deadline,
    ) else {
        return false;
    };
    let Ok(value) = serde_json::from_slice::<serde_json::Value>(&bytes) else {
        return false;
    };
    let Some(devices) = value.get("blockdevices").and_then(|value| value.as_array()) else {
        return false;
    };
    fn collect_members<'a>(
        devices: &'a [serde_json::Value],
        parent_transport: Option<&'a str>,
        members: &mut Vec<(&'a str, &'a str, Option<&'a str>)>,
    ) {
        for device in devices {
            let transport = device
                .get("tran")
                .and_then(|value| value.as_str())
                .or(parent_transport);
            if device.get("fstype").and_then(|value| value.as_str()) == Some("btrfs")
                && let Some(path) = device.get("path").and_then(|value| value.as_str())
                && let Some(uuid) = device.get("uuid").and_then(|value| value.as_str())
                && !uuid.is_empty()
            {
                members.push((path, uuid, transport));
            }
            if let Some(children) = device.get("children").and_then(|value| value.as_array()) {
                collect_members(children, transport, members);
            }
        }
    }
    let mut members = Vec::new();
    collect_members(devices, None, &mut members);
    let Some((_, uuid, _)) = members
        .iter()
        .find(|(path, _, _)| std::path::Path::new(path) == device)
    else {
        return false;
    };
    // A missing mirror is allowed; every attached member must still be USB.
    members
        .iter()
        .filter(|(_, candidate, _)| candidate == uuid)
        .all(|(_, _, transport)| *transport == Some("usb"))
}

pub fn check(host: Host) -> Health {
    let deadline = Instant::now() + BUDGET;
    let mut checks = BTreeMap::new();
    std::thread::scope(|scope| {
        let network = scope.spawn(|| network(host, deadline));
        let dns = scope.spawn(|| dns(host, deadline));
        let cloudflare = scope.spawn(|| https(HTTPS[0], deadline));
        let google = scope.spawn(|| https(HTTPS[1], deadline));
        let tailscale = scope.spawn(|| tailscale(deadline));
        let management = scope.spawn(|| match host {
            Host::Renekton => openclaw("/healthz", deadline),
            Host::Jayce | Host::Ahri => ssh(deadline),
        });
        let startup = if host == Host::Renekton {
            Some(scope.spawn(|| openclaw("/startupz", deadline)))
        } else {
            None
        };
        let control_plane = if host == Host::Ahri {
            Some((
                scope.spawn(|| caddy(deadline)),
                scope.spawn(|| usb_root(deadline)),
            ))
        } else {
            None
        };
        checks.insert("network", result(network.join().unwrap_or(false)));
        checks.insert("dns", result(dns.join().unwrap_or(false)));
        let https_ok = cloudflare.join().unwrap_or(false) | google.join().unwrap_or(false);
        checks.insert("https", result(https_ok));
        checks.insert("tailscale", result(tailscale.join().unwrap_or(false)));
        let management_ok = management.join().unwrap_or(false);
        if let Some(startup) = startup {
            let startup_ok = startup.join().unwrap_or(false);
            checks.insert("openclaw_healthz", result(management_ok));
            checks.insert("openclaw_startupz", result(startup_ok));
            checks.insert("openclaw", result(management_ok && startup_ok));
        } else {
            checks.insert("management_ssh", result(management_ok));
        }
        if let Some((caddy, root)) = control_plane {
            checks.insert("caddy", result(caddy.join().unwrap_or(false)));
            checks.insert("usb_root", result(root.join().unwrap_or(false)));
        }
    });
    let ok = checks.values().all(|probe| probe.ok);
    Health {
        ok,
        summary: if ok { "host healthy" } else { "host unhealthy" },
        checks,
    }
}
