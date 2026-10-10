//! D-Bus interfaces of the Linux system services wave talks to.

use zbus::proxy;
use zbus::zvariant::{OwnedFd, OwnedObjectPath};

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
}

#[proxy(
    interface = "org.freedesktop.systemd1.Manager",
    default_service = "org.freedesktop.systemd1",
    default_path = "/org/freedesktop/systemd1"
)]
pub trait SystemdManager {
    fn stop_unit(&self, name: &str, mode: &str) -> zbus::Result<OwnedObjectPath>;
}
