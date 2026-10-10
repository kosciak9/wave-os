//! Use performance on AC or with caffeinate, otherwise save battery power.
//!
//! A profile is applied only when the power source or caffeinate changes, so
//! a manual switch holds until the next such transition.

use crate::dbus::{LoginManagerProxyBlocking, PowerProfilesProxyBlocking, UPowerProxyBlocking};
use anyhow::{Context, Result, bail};
use std::sync::mpsc;
use zbus::blocking::Connection;
use zbus::blocking::fdo::PropertiesProxy;
use zbus::proxy::CacheProperties;

/// Owner of the inhibitor `wave caffeinate hold` takes.
const CAFFEINATE: &str = "wave-caffeinate";

enum Event {
    Changed,
    Lost(&'static str),
}

/// Runs until a bus connection or signal stream fails; systemd restarts it.
pub fn run() -> Result<i32> {
    let bus = Connection::system().context("system bus unavailable")?;
    let login = LoginManagerProxyBlocking::new(&bus)?;
    let upower = UPowerProxyBlocking::builder(&bus)
        .cache_properties(CacheProperties::No)
        .build()?;
    let profiles = PowerProfilesProxyBlocking::builder(&bus)
        .cache_properties(CacheProperties::No)
        .build()?;

    let (events, changes) = mpsc::channel();
    // logind signals every inhibitor start and stop through
    // NCurrentInhibitors, even when the aggregate masks stay the same;
    // UPower signals OnBattery.
    for (service, path, name) in [
        (
            "org.freedesktop.login1",
            "/org/freedesktop/login1",
            "logind",
        ),
        (
            "org.freedesktop.UPower",
            "/org/freedesktop/UPower",
            "UPower",
        ),
    ] {
        let signals = PropertiesProxy::builder(&bus)
            .destination(service)?
            .path(path)?
            .build()?
            .receive_properties_changed()?;
        let events = events.clone();
        std::thread::spawn(move || {
            for _ in signals {
                if events.send(Event::Changed).is_err() {
                    return;
                }
            }
            let _ = events.send(Event::Lost(name));
        });
    }
    drop(events);

    let mut applied_for = None;
    let mut caffeinated = None;
    loop {
        let active = login
            .list_inhibitors()?
            .iter()
            .any(|(what, who, _, mode, _, _)| {
                who == CAFFEINATE
                    && what.split(':').any(|kind| kind == "sleep")
                    && (mode == "block" || mode == "block-weak")
            });
        if caffeinated != Some(active) {
            eprintln!(
                "wave power-profile: caffeinate {}",
                if active { "enabled" } else { "disabled" }
            );
            caffeinated = Some(active);
        }
        let on_battery = upower.on_battery()?;
        if applied_for != Some((active, on_battery)) {
            apply(&profiles, active || !on_battery)?;
            applied_for = Some((active, on_battery));
        }
        match changes.recv() {
            Ok(Event::Changed) => {}
            Ok(Event::Lost(name)) => bail!("{name} property signals ended"),
            Err(_) => bail!("all signal streams stopped"),
        }
    }
}

fn apply(profiles: &PowerProfilesProxyBlocking<'_>, performance: bool) -> Result<()> {
    let available: Vec<String> = profiles
        .profiles()?
        .iter()
        .filter_map(|profile| String::try_from(profile.get("Profile")?.try_clone().ok()?).ok())
        .collect();
    let desired = match performance {
        false => "power-saver",
        true if available.iter().any(|profile| profile == "performance") => "performance",
        true => {
            eprintln!("wave power-profile: performance unavailable; using balanced");
            "balanced"
        }
    };
    if profiles.active_profile()? == desired {
        return Ok(());
    }
    match profiles.set_active_profile(desired) {
        Ok(()) => eprintln!("wave power-profile: set {desired}"),
        // The performance profile can be degraded or held back at runtime.
        Err(error) if desired == "performance" => {
            eprintln!("wave power-profile: performance refused ({error}); using balanced");
            profiles.set_active_profile("balanced")?;
        }
        Err(error) => return Err(error).context(format!("cannot set {desired}")),
    }
    Ok(())
}
