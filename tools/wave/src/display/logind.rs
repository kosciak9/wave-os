use anyhow::{Context, Result};
use std::sync::mpsc::Sender;
use zbus::blocking::Connection;
use zbus::blocking::fdo::PropertiesProxy;
use zbus::names::InterfaceName;
use zbus::zvariant::OwnedFd;

use crate::dbus::{LoginManagerProxyBlocking, SessionProxyBlocking, SystemdManagerProxyBlocking};

/// Logind properties whose change can alter the lid or sleep decision.
const WATCHED_PROPERTIES: &[&str] = &["LidClosed", "BlockInhibited", "BlockWeakInhibited"];

#[derive(Debug)]
pub enum Event {
    Changed,
    Resumed,
    Lost(String),
}

pub struct Logind {
    system: Connection,
    session: Connection,
}

impl Logind {
    pub fn connect() -> Result<Self> {
        Ok(Self {
            system: Connection::system().context("system bus unavailable")?,
            session: Connection::session().context("session bus unavailable")?,
        })
    }

    fn manager(&self) -> zbus::Result<LoginManagerProxyBlocking<'_>> {
        LoginManagerProxyBlocking::new(&self.system)
    }

    /// Holds lid handling away from logind for as long as the descriptor lives,
    /// so a dead daemon hands the lid straight back to logind's own policy.
    pub fn inhibit_lid_switch(&self) -> Result<OwnedFd> {
        self.manager()?
            .inhibit(
                "handle-lid-switch",
                "wave display",
                "Wave display policy owns lid actions",
                "block",
            )
            .context("cannot take the lid switch from logind")
    }

    /// Fails closed: an unreadable reply counts as inhibited, and so does a
    /// weak lock such as caffeinate's, which logind would let its owner bypass.
    pub fn sleep_inhibited(&self, idle: bool) -> bool {
        let Ok(inhibitors) = self.manager().and_then(|manager| manager.list_inhibitors()) else {
            return true;
        };
        inhibitors.iter().any(|(what, _, _, mode, _, _)| {
            (mode == "block" || mode == "block-weak")
                && what
                    .split(':')
                    .any(|kind| kind == "sleep" || (idle && kind == "idle"))
        })
    }

    pub fn sleep(&self) -> Result<&'static str> {
        let manager = self.manager()?;
        if manager.can_suspend_then_hibernate().as_deref() == Ok("yes") {
            manager.suspend_then_hibernate(false)?;
            Ok("suspend-then-hibernate")
        } else {
            manager.suspend(false)?;
            Ok("suspend")
        }
    }

    pub fn lock_session(&self) -> Result<()> {
        SessionProxyBlocking::new(&self.system)?.lock()?;
        Ok(())
    }

    pub fn stop_user_unit(&self, unit: &str) -> Result<()> {
        SystemdManagerProxyBlocking::new(&self.session)?.stop_unit(unit, "replace")?;
        Ok(())
    }

    /// Forwards logind's own signals; a closed stream means the bus is gone,
    /// which the daemon treats as fatal so systemd starts it afresh.
    pub fn follow<T: From<Event> + Send + 'static>(&self, events: Sender<T>) -> Result<()> {
        let manager = self.manager()?;
        let sleeps = manager.receive_prepare_for_sleep()?;
        let sleep_events = events.clone();
        std::thread::spawn(move || {
            for signal in sleeps {
                let resumed = signal.args().is_ok_and(|args| !args.start);
                if resumed && sleep_events.send(Event::Resumed.into()).is_err() {
                    return;
                }
            }
            let _ = sleep_events.send(Event::Lost("logind sleep signals ended".into()).into());
        });

        let properties = PropertiesProxy::builder(&self.system)
            .destination("org.freedesktop.login1")?
            .path("/org/freedesktop/login1")?
            .build()?;
        let changes = properties.receive_properties_changed()?;
        let interface = InterfaceName::from_static_str_unchecked("org.freedesktop.login1.Manager");
        std::thread::spawn(move || {
            for signal in changes {
                let relevant = signal.args().is_ok_and(|args| {
                    args.interface_name == interface
                        && (args
                            .changed_properties
                            .keys()
                            .any(|name| WATCHED_PROPERTIES.contains(name))
                            || args
                                .invalidated_properties
                                .iter()
                                .any(|name| WATCHED_PROPERTIES.contains(name)))
                });
                if relevant && events.send(Event::Changed.into()).is_err() {
                    return;
                }
            }
            let _ = events.send(Event::Lost("logind property signals ended".into()).into());
        });
        Ok(())
    }
}
