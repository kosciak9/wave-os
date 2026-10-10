//! D-Bus interfaces of the Linux system services wave talks to.

use std::collections::HashMap;
use zbus::proxy;
use zbus::zvariant::{ObjectPath, OwnedFd, OwnedObjectPath, OwnedValue};

/// (what, who, why, mode, uid, pid)
pub type Inhibitor = (String, String, String, String, u32, u32);

#[proxy(
    interface = "org.freedesktop.login1.Manager",
    default_service = "org.freedesktop.login1",
    default_path = "/org/freedesktop/login1"
)]
pub trait LoginManager {
    fn inhibit(&self, what: &str, who: &str, why: &str, mode: &str) -> zbus::Result<OwnedFd>;
    fn list_inhibitors(&self) -> zbus::Result<Vec<Inhibitor>>;
    fn can_suspend_then_hibernate(&self) -> zbus::Result<String>;
    fn suspend(&self, interactive: bool) -> zbus::Result<()>;
    fn suspend_then_hibernate(&self, interactive: bool) -> zbus::Result<()>;
    #[zbus(signal)]
    fn prepare_for_sleep(&self, start: bool) -> zbus::Result<()>;
}

#[proxy(
    interface = "org.freedesktop.login1.Session",
    default_service = "org.freedesktop.login1",
    default_path = "/org/freedesktop/login1/session/auto"
)]
pub trait Session {
    fn lock(&self) -> zbus::Result<()>;
    fn set_brightness(&self, subsystem: &str, name: &str, brightness: u32) -> zbus::Result<()>;
}

#[proxy(
    interface = "org.freedesktop.systemd1.Manager",
    default_service = "org.freedesktop.systemd1",
    default_path = "/org/freedesktop/systemd1"
)]
pub trait SystemdManager {
    fn start_unit(&self, name: &str, mode: &str) -> zbus::Result<OwnedObjectPath>;
    fn stop_unit(&self, name: &str, mode: &str) -> zbus::Result<OwnedObjectPath>;
    fn load_unit(&self, name: &str) -> zbus::Result<OwnedObjectPath>;
    /// Unit and job signals are only emitted to subscribed clients.
    fn subscribe(&self) -> zbus::Result<()>;
    #[zbus(signal)]
    fn job_removed(
        &self,
        id: u32,
        job: ObjectPath<'_>,
        unit: &str,
        result: &str,
    ) -> zbus::Result<()>;
}

#[proxy(
    interface = "org.freedesktop.systemd1.Unit",
    default_service = "org.freedesktop.systemd1"
)]
pub trait SystemdUnit {
    #[zbus(property)]
    fn active_state(&self) -> zbus::Result<String>;
}

#[proxy(
    interface = "org.freedesktop.UPower",
    default_service = "org.freedesktop.UPower",
    default_path = "/org/freedesktop/UPower"
)]
pub trait UPower {
    #[zbus(property)]
    fn on_battery(&self) -> zbus::Result<bool>;
}

#[proxy(
    interface = "org.freedesktop.UPower.PowerProfiles",
    default_service = "org.freedesktop.UPower.PowerProfiles",
    default_path = "/org/freedesktop/UPower/PowerProfiles"
)]
pub trait PowerProfiles {
    #[zbus(property)]
    fn active_profile(&self) -> zbus::Result<String>;
    #[zbus(property)]
    fn set_active_profile(&self, profile: &str) -> zbus::Result<()>;
    #[zbus(property)]
    fn profiles(&self) -> zbus::Result<Vec<HashMap<String, OwnedValue>>>;
}

#[proxy(
    interface = "org.freedesktop.GeoClue2.Manager",
    default_service = "org.freedesktop.GeoClue2",
    default_path = "/org/freedesktop/GeoClue2/Manager"
)]
pub trait GeoClueManager {
    fn get_client(&self) -> zbus::Result<OwnedObjectPath>;
}

#[proxy(
    interface = "org.freedesktop.GeoClue2.Client",
    default_service = "org.freedesktop.GeoClue2"
)]
pub trait GeoClueClient {
    fn start(&self) -> zbus::Result<()>;
    #[zbus(property)]
    fn set_desktop_id(&self, id: &str) -> zbus::Result<()>;
    #[zbus(property)]
    fn set_requested_accuracy_level(&self, level: u32) -> zbus::Result<()>;
    #[zbus(property)]
    fn set_distance_threshold(&self, meters: u32) -> zbus::Result<()>;
    #[zbus(signal)]
    fn location_updated(&self, old: ObjectPath<'_>, new: ObjectPath<'_>) -> zbus::Result<()>;
}

#[proxy(
    interface = "org.freedesktop.GeoClue2.Location",
    default_service = "org.freedesktop.GeoClue2"
)]
pub trait GeoClueLocation {
    #[zbus(property)]
    fn latitude(&self) -> zbus::Result<f64>;
    #[zbus(property)]
    fn longitude(&self) -> zbus::Result<f64>;
}
