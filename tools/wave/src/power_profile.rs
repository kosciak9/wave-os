//! Use performance on AC, otherwise balanced to keep Wi-Fi stable.
//!
//! A profile is applied only when the power source changes, so a manual switch
//! holds until the next such transition.

use crate::dbus::{PowerProfilesProxyBlocking, UPowerProxyBlocking};
use anyhow::{Context, Result, bail};
use zbus::blocking::Connection;
use zbus::blocking::fdo::PropertiesProxy;
use zbus::proxy::CacheProperties;

/// Runs until a bus connection or signal stream fails; systemd restarts it.
pub fn run() -> Result<i32> {
    let bus = Connection::system().context("system bus unavailable")?;
    let upower = UPowerProxyBlocking::builder(&bus)
        .cache_properties(CacheProperties::No)
        .build()?;
    let profiles = PowerProfilesProxyBlocking::builder(&bus)
        .cache_properties(CacheProperties::No)
        .build()?;

    let mut changes = PropertiesProxy::builder(&bus)
        .destination("org.freedesktop.UPower")?
        .path("/org/freedesktop/UPower")?
        .build()?
        .receive_properties_changed()?;

    let mut applied_for = None;
    loop {
        let on_battery = upower.on_battery()?;
        if applied_for != Some(on_battery) {
            apply(&profiles, !on_battery)?;
            applied_for = Some(on_battery);
        }
        if changes.next().is_none() {
            bail!("UPower property signals ended");
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
        false => "balanced",
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
