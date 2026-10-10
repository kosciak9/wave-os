use super::hyprland::{Hyprland, Monitor, Notice};
use super::logind::Logind;
use super::ownership::{EVENT_DELAY, Ownership, description_identity};
use serde::Serialize;
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::time::{Duration, Instant};

pub const INTERNAL: &str = "eDP-1";
/// Our own workspace moves expire when Hyprland never reports them.
const GENERATED_EVENT_TIMEOUT: Duration = Duration::from_secs(5);
/// After waking, the user gets this long before a pending sleep is retried.
const RESUME_SLEEP_GRACE: Duration = Duration::from_secs(5);
/// Hyprland settles a newly added output before workspaces can follow it.
const OUTPUT_SETTLE: Duration = Duration::from_millis(250);
const BLACKOUT_SETTLE: Duration = Duration::from_millis(80);
const MOVE_CONFIRM_ATTEMPTS: u32 = 15;
const MOVE_CONFIRM_INTERVAL: Duration = Duration::from_millis(80);
const INTERNAL_RETURN_ATTEMPTS: u32 = 40;
const INTERNAL_RETURN_INTERVAL: Duration = Duration::from_millis(100);

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Lid {
    Open,
    Closed,
    Unknown,
}

/// ACPI reports the switch before the input event that notifies us, so a
/// fresh read always agrees with the event being handled.
pub fn lid_state() -> Lid {
    let Ok(entries) = std::fs::read_dir("/proc/acpi/button/lid") else {
        return Lid::Unknown;
    };
    for entry in entries.flatten() {
        if let Ok(text) = std::fs::read_to_string(entry.path().join("state"))
            && let Some((_, value)) = text.split_once(':')
        {
            return if value.trim().to_lowercase().starts_with("closed") {
                Lid::Closed
            } else {
                Lid::Open
            };
        }
    }
    Lid::Unknown
}

/// What the Control Center tile shows: whether the lid override can be
/// offered, and whether it is on.
#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
pub struct Status {
    pub available: bool,
    pub active: bool,
}

#[derive(Clone, Copy, Debug)]
pub enum Action {
    LidClose,
    LidOpen,
    IdleStart,
    IdleEnd,
    DisplayOn,
}

impl Action {
    pub fn parse(name: &str) -> Option<Self> {
        Some(match name {
            "lid-close" => Self::LidClose,
            "lid-open" => Self::LidOpen,
            "idle-start" => Self::IdleStart,
            "idle-end" => Self::IdleEnd,
            "display-on" => Self::DisplayOn,
            _ => return None,
        })
    }
}

/// The Framework 16 keyboard module drives its own backlight through QMK;
/// the EC's kbd_backlight LED does not reach it.
fn qmk_backlight(level: Option<u8>) -> Option<String> {
    let mut command = std::process::Command::new("qmk_hid");
    command
        .args(["via", "--backlight"])
        .args(level.map(|level| level.to_string()))
        .stderr(std::process::Stdio::null());
    match crate::process::capture(&mut command, Duration::from_secs(2)) {
        Ok(output) if output.success() => Some(String::from_utf8_lossy(&output.stdout).into()),
        Ok(output) => {
            eprintln!("wave display: qmk_hid failed ({})", output.code);
            None
        }
        Err(error) => {
            eprintln!("wave display: qmk_hid failed: {error:#}");
            None
        }
    }
}

fn keyboard_backlight() -> Option<u8> {
    let output = qmk_backlight(None)?;
    let percent = output
        .split("Brightness:")
        .nth(1)?
        .trim()
        .strip_suffix('%')?;
    percent.trim().parse().ok()
}

fn set_keyboard_backlight(level: u8) {
    qmk_backlight(Some(level));
}

fn lua_string(value: &str) -> String {
    serde_json::to_string(value).expect("strings serialize")
}

fn has_external(monitors: &[Monitor]) -> bool {
    monitors.iter().any(|monitor| monitor.name != INTERNAL)
}

fn has_internal(monitors: &[Monitor]) -> bool {
    monitors.iter().any(|monitor| monitor.name == INTERNAL)
}

/// Brings outputs, workspaces and sleep in line with the lid, the override
/// and the live topology. Every decision is taken from what Hyprland and
/// the hardware report now, so any event repairs any earlier drift.
pub struct Reconciler {
    hyprland: Hyprland,
    logind: Logind,
    pub ownership: Ownership,
    /// While present, Hyprland's config keeps eDP-1 disabled across reloads.
    internal_off_marker: PathBuf,
    generated: HashMap<i64, (String, Instant)>,
    last_external: String,
    frozen_last_active: HashSet<String>,
    last_lid: Lid,
    external_present: bool,
    suspend_requested: bool,
    suspend_retry_at: Option<Instant>,
    suspend_delay: Duration,
    idle_requested: bool,
    deferred_snapshot_at: Option<Instant>,
}

impl Reconciler {
    pub fn new(
        hyprland: Hyprland,
        logind: Logind,
        ownership: Ownership,
        internal_off_marker: PathBuf,
    ) -> Self {
        Self {
            hyprland,
            logind,
            ownership,
            internal_off_marker,
            generated: HashMap::new(),
            last_external: String::new(),
            frozen_last_active: HashSet::new(),
            last_lid: lid_state(),
            external_present: false,
            suspend_requested: false,
            suspend_retry_at: None,
            suspend_delay: Duration::from_secs(1),
            idle_requested: false,
            deferred_snapshot_at: None,
        }
    }

    fn override_active(&self) -> bool {
        self.ownership.state.lid_override.is_some()
    }

    fn clear_override(&mut self, reason: &str) {
        if self.ownership.state.lid_override.take().is_some() {
            eprintln!("wave display: lid override cleared: {reason}");
        }
    }

    pub fn status(&self) -> Status {
        Status {
            available: lid_state() == Lid::Open && self.external_present,
            active: self.override_active(),
        }
    }

    pub fn set_override(&mut self, enabled: bool) -> Result<Status, String> {
        if enabled == self.override_active() {
            return Ok(self.status());
        }
        if enabled {
            if self.snapshot().is_none() {
                return Err("Hyprland is not answering".into());
            }
            if !self.status().available {
                return Err("needs an open lid and an external display".into());
            }
            self.ownership.state.lid_override = Some(self.hyprland.signature.clone());
        } else {
            self.clear_override("turned off");
        }
        self.converge(false);
        Ok(self.status())
    }

    pub fn action(&mut self, action: Action) {
        match action {
            Action::LidClose => self.converge(false),
            Action::LidOpen => {
                self.idle_requested = false;
                self.suspend_requested = false;
                self.reset_sleep_retry();
                self.converge(true);
            }
            Action::IdleStart => {
                self.idle_requested = true;
                if let Ok(monitors) = self.hyprland.monitors() {
                    for monitor in &monitors {
                        self.set_dpms(monitor, false);
                    }
                }
                self.converge(false);
            }
            Action::IdleEnd => {
                self.idle_requested = false;
                // A closed lid without an external display still wants sleep.
                if lid_state() != Lid::Closed {
                    self.reset_sleep_retry();
                }
            }
            Action::DisplayOn => self.converge(true),
        }
    }

    pub fn resumed(&mut self) {
        self.suspend_requested = false;
        self.idle_requested = false;
        self.suspend_delay = RESUME_SLEEP_GRACE;
        self.suspend_retry_at = Some(Instant::now() + RESUME_SLEEP_GRACE);
        self.converge(true);
    }

    /// Lid or inhibitor state changed in logind. Activity from clicking a
    /// toggle gets a moment to cancel an expired idle request before sleep.
    pub fn logind_changed(&mut self) {
        self.suspend_retry_at = Some(Instant::now() + EVENT_DELAY);
        self.suspend_delay = Duration::from_secs(1);
        self.converge(false);
    }

    pub fn hyprland_connected(&mut self) {
        self.deferred_snapshot_at = None;
        self.converge(false);
    }

    pub fn hyprland_disconnected(&mut self) {
        self.deferred_snapshot_at = None;
    }

    pub fn hyprland_notice(&mut self, notice: Notice<'_>) {
        match notice {
            Notice::WorkspaceMoved { id, monitor } => {
                let generated = self
                    .generated
                    .remove(&id)
                    .is_some_and(|(target, _)| target == monitor);
                self.ownership.move_event(id, monitor, generated);
            }
            Notice::WorkspaceDestroyed { id } => {
                self.ownership.destroy_workspace(id);
                self.generated.remove(&id);
            }
            Notice::MonitorRemoved { name } => {
                self.deferred_snapshot_at = None;
                self.ownership.monitor_removed(name);
                self.during_topology_change(|reconciler| reconciler.converge(false));
            }
            Notice::MonitorAdded { name, description } => {
                self.deferred_snapshot_at = None;
                let identity = description_identity(description);
                self.ownership.monitor_added(name, identity.as_deref());
                self.during_topology_change(|reconciler| {
                    std::thread::sleep(OUTPUT_SETTLE);
                    reconciler.converge(false);
                });
            }
            Notice::ConfigReloaded => self.converge(false),
            Notice::ActiveChanged => {
                self.deferred_snapshot_at = Some(Instant::now() + EVENT_DELAY);
            }
        }
    }

    /// Timed follow-ups; returns when the next one is due.
    pub fn tick(&mut self) -> Option<Instant> {
        let now = Instant::now();
        if self.deferred_snapshot_at.is_some_and(|due| now >= due) {
            self.deferred_snapshot_at = None;
            self.snapshot();
        }
        if !self.suspend_requested && self.suspend_retry_at.is_some_and(|due| now >= due) {
            if lid_state() == Lid::Closed {
                self.converge(false);
            } else {
                self.settle_sleep();
            }
        }
        self.ownership.flush();
        self.generated
            .retain(|_, (_, stamp)| stamp.elapsed() <= GENERATED_EVENT_TIMEOUT);

        let generated_expiry = self
            .generated
            .values()
            .map(|(_, stamp)| *stamp + GENERATED_EVENT_TIMEOUT)
            .min();
        let retry = self.suspend_retry_at.filter(|_| !self.suspend_requested);
        [
            self.deferred_snapshot_at,
            retry,
            self.ownership.next_flush(),
            generated_expiry,
        ]
        .into_iter()
        .flatten()
        .min()
    }

    /// Hyprland picks active workspaces on its own while outputs come and
    /// go; keep what was active before so restoration can put it back.
    fn during_topology_change(&mut self, change: impl FnOnce(&mut Self)) {
        self.frozen_last_active = self
            .ownership
            .state
            .last_active
            .iter()
            .filter(|(_, id)| **id > 0)
            .map(|(identity, _)| identity.clone())
            .collect();
        change(self);
        self.frozen_last_active.clear();
    }

    fn snapshot(&mut self) -> Option<Vec<Monitor>> {
        let monitors = self
            .hyprland
            .monitors()
            .map_err(|error| eprintln!("wave display: {error:#}"))
            .ok()?;
        let workspaces = self
            .hyprland
            .workspaces()
            .map_err(|error| eprintln!("wave display: {error:#}"))
            .ok()?;
        self.ownership.map_outputs(&monitors);

        let managed: HashSet<i64> = workspaces
            .iter()
            .filter(|workspace| workspace.managed())
            .map(|workspace| workspace.id)
            .collect();
        let gone: Vec<i64> = self
            .ownership
            .state
            .workspaces
            .keys()
            .filter(|id| !managed.contains(id))
            .copied()
            .collect();
        for id in gone {
            self.ownership.destroy_workspace(id);
            self.generated.remove(&id);
        }
        for workspace in workspaces.iter().filter(|workspace| workspace.managed()) {
            let identity = self.ownership.identity_of(&workspace.monitor);
            let record = self.ownership.record(workspace.id);
            record.current_connector = workspace.monitor.clone();
            record.desired_identity.get_or_insert(identity);
        }
        for monitor in &monitors {
            let identity = self.ownership.identity_of(&monitor.name);
            if monitor.active_workspace.id > 0 && !self.frozen_last_active.contains(&identity) {
                self.ownership
                    .state
                    .last_active
                    .insert(identity.clone(), monitor.active_workspace.id);
            }
            if monitor.focused && monitor.name != INTERNAL {
                self.last_external = monitor.name.clone();
                self.ownership.state.preferred_external = identity;
            }
        }
        self.external_present = has_external(&monitors);
        Some(monitors)
    }

    pub fn converge(&mut self, wake_displays: bool) {
        let lid = lid_state();
        if lid != self.last_lid && lid != Lid::Unknown && self.last_lid != Lid::Unknown {
            self.clear_override("the lid moved");
        }
        self.last_lid = lid;

        let Some(monitors) = self.snapshot() else {
            if lid == Lid::Closed || self.override_active() {
                self.dpms(INTERNAL, false);
            }
            self.defer_sleep();
            return;
        };
        if self.override_active() && !self.external_present {
            self.clear_override("no external display");
        }

        if lid == Lid::Closed || self.override_active() {
            self.converge_closed(&monitors, lid);
            if wake_displays && let Ok(monitors) = self.hyprland.monitors() {
                for monitor in monitors.iter().filter(|monitor| monitor.name != INTERNAL) {
                    self.set_dpms(monitor, true);
                }
            }
        } else {
            self.converge_open(monitors, wake_displays);
        }
    }

    fn converge_closed(&mut self, monitors: &[Monitor], lid: Lid) {
        if let Some(internal) = monitors.iter().find(|monitor| monitor.name == INTERNAL) {
            self.set_dpms(internal, false);
        }
        // Only a lid closed without an external display locks and sleeps;
        // with one, the session carries on there.
        if !has_external(monitors) {
            if lid == Lid::Closed {
                self.stop_dim();
                if let Err(error) = self.logind.lock_session() {
                    eprintln!("wave display: lock failed: {error:#}");
                }
                self.request_sleep(false);
            }
            return;
        }
        if has_internal(monitors) {
            if !self.evacuate_internal(monitors) {
                self.defer_sleep();
                return;
            }
        } else {
            self.mark_internal_off();
            self.restore_outputs(monitors);
        }
        self.darken_keyboard();
        self.settle_sleep();
    }

    fn converge_open(&mut self, monitors: Vec<Monitor>, wake_displays: bool) {
        let monitors = if has_internal(&monitors) {
            self.clear_internal_off_marker();
            monitors
        } else {
            match self.enable_internal() {
                Some(monitors) => monitors,
                None => {
                    self.defer_sleep();
                    return;
                }
            }
        };
        self.restore_keyboard();
        self.restore_outputs(&monitors);
        if wake_displays {
            for monitor in &monitors {
                self.set_dpms(monitor, true);
            }
        }
        self.settle_sleep();
    }

    fn mark_internal_off(&self) -> bool {
        std::fs::write(&self.internal_off_marker, b"")
            .map_err(|error| eprintln!("wave display: cannot mark eDP-1 off: {error}"))
            .is_ok()
    }

    fn clear_internal_off_marker(&self) -> bool {
        match std::fs::remove_file(&self.internal_off_marker) {
            Ok(()) => true,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => true,
            Err(error) => {
                eprintln!("wave display: cannot clear the eDP-1 off marker: {error}");
                false
            }
        }
    }

    /// Moves managed workspaces off eDP-1, then disables it; true once done.
    fn evacuate_internal(&mut self, monitors: &[Monitor]) -> bool {
        let Some(target) = self.target_external(monitors) else {
            eprintln!("wave display: no external display to move workspaces to");
            return false;
        };
        let on_internal = |reconciler: &Self| -> Option<Vec<i64>> {
            let workspaces = reconciler
                .hyprland
                .workspaces()
                .map_err(|error| eprintln!("wave display: {error:#}"))
                .ok()?;
            Some(
                workspaces
                    .iter()
                    .filter(|workspace| workspace.monitor == INTERNAL && workspace.managed())
                    .map(|workspace| workspace.id)
                    .collect(),
            )
        };
        let Some(internal_workspaces) = on_internal(self) else {
            return false;
        };
        if !internal_workspaces.is_empty() {
            self.blackout();
            self.stop_dim();
            for id in internal_workspaces {
                self.move_workspace(id, &target);
            }
            if on_internal(self).is_none_or(|remaining| !remaining.is_empty()) {
                return false;
            }
        }
        if !self.mark_internal_off() {
            return false;
        }
        self.hyprland
            .eval(&format!(
                "hl.monitor({{ output = {}, disabled = true }})",
                lua_string(INTERNAL)
            ))
            .map_err(|error| eprintln!("wave display: {error:#}"))
            .is_ok()
    }

    /// Reloads Hyprland's config without the off marker to bring eDP-1 back.
    fn enable_internal(&mut self) -> Option<Vec<Monitor>> {
        if !self.clear_internal_off_marker() {
            return None;
        }
        let mut monitors = None;
        self.during_topology_change(|reconciler| {
            reconciler.blackout();
            if let Err(error) = reconciler.hyprland.reload() {
                eprintln!("wave display: {error:#}");
                return;
            }
            for _ in 0..INTERNAL_RETURN_ATTEMPTS {
                if let Some(current) = reconciler.snapshot()
                    && has_internal(&current)
                {
                    monitors = Some(current);
                    return;
                }
                std::thread::sleep(INTERNAL_RETURN_INTERVAL);
            }
            eprintln!("wave display: eDP-1 did not return after reload");
        });
        monitors
    }

    fn target_external(&self, monitors: &[Monitor]) -> Option<String> {
        let external: Vec<&Monitor> = monitors
            .iter()
            .filter(|monitor| monitor.name != INTERNAL)
            .collect();
        let preferred = external.iter().find(|monitor| {
            self.ownership.identity_of(&monitor.name) == self.ownership.state.preferred_external
                || monitor.name == self.last_external
        });
        preferred
            .or_else(|| external.iter().find(|monitor| monitor.focused))
            .or_else(|| external.iter().min_by(|a, b| a.name.cmp(&b.name)))
            .map(|monitor| monitor.name.clone())
    }

    fn move_workspace(&mut self, id: i64, target: &str) -> bool {
        if self
            .ownership
            .state
            .workspaces
            .get(&id)
            .is_some_and(|record| record.current_connector == target)
        {
            return true;
        }
        self.generated.insert(id, (target.into(), Instant::now()));
        let command = format!(
            "hl.dsp.workspace.move({{ workspace = {}, monitor = {} }})",
            lua_string(&id.to_string()),
            lua_string(target)
        );
        if let Err(error) = self.hyprland.dispatch(&command) {
            eprintln!("wave display: {error:#}");
            self.generated.remove(&id);
            return false;
        }
        for _ in 0..MOVE_CONFIRM_ATTEMPTS {
            let arrived = self.hyprland.workspaces().is_ok_and(|workspaces| {
                workspaces
                    .iter()
                    .any(|workspace| workspace.id == id && workspace.monitor == target)
            });
            if arrived {
                self.ownership.record(id).current_connector = target.into();
                return true;
            }
            std::thread::sleep(MOVE_CONFIRM_INTERVAL);
        }
        eprintln!("wave display: workspace {id} did not reach {target}");
        self.generated.remove(&id);
        false
    }

    /// The workspace last active on `connector`, if it is still there.
    fn last_active_on(&self, connector: &str) -> Option<i64> {
        let identity = self.ownership.identity_of(connector);
        let id = *self.ownership.state.last_active.get(&identity)?;
        let record = self.ownership.state.workspaces.get(&id)?;
        (id > 0 && record.current_connector == connector).then_some(id)
    }

    /// Returns workspaces to the outputs the user placed them on. Focus is
    /// only rearranged after something moved or the topology changed, so
    /// routine events never steal focus or warp the cursor.
    fn restore_outputs(&mut self, monitors: &[Monitor]) {
        let previous_focus = monitors
            .iter()
            .find(|monitor| monitor.focused)
            .map(|monitor| monitor.name.clone());
        self.ownership.map_outputs(monitors);
        let moves: Vec<(i64, String)> = self
            .ownership
            .state
            .workspaces
            .iter()
            .filter_map(|(id, record)| {
                let target = self
                    .ownership
                    .connector_of(record.desired_identity.as_deref()?)?;
                (*id > 0 && record.current_connector != target).then(|| (*id, target.to_owned()))
            })
            .collect();
        let moved = !moves.is_empty();
        for (id, target) in moves {
            self.move_workspace(id, &target);
        }
        if !moved && self.frozen_last_active.is_empty() {
            return;
        }

        let connected: Vec<String> = self.ownership.connected().map(String::from).collect();
        for target in &connected {
            let Some(id) = self.last_active_on(target) else {
                continue;
            };
            let focus_monitor = format!("hl.dsp.focus({{ monitor = {} }})", lua_string(target));
            let focused = self.hyprland.dispatch(&focus_monitor);
            if focused.is_ok() && self.last_active_on(target) == Some(id) {
                let focus_workspace = format!(
                    "hl.dsp.focus({{ workspace = {}, on_current_monitor = true }})",
                    lua_string(&id.to_string())
                );
                if let Err(error) = self.hyprland.dispatch(&focus_workspace) {
                    eprintln!("wave display: {error:#}");
                }
            }
            if let Some(previous) = previous_focus
                .as_ref()
                .filter(|previous| connected.contains(previous))
            {
                let refocus = format!("hl.dsp.focus({{ monitor = {} }})", lua_string(previous));
                if let Err(error) = self.hyprland.dispatch(&refocus) {
                    eprintln!("wave display: {error:#}");
                }
            }
        }
    }

    fn set_dpms(&self, monitor: &Monitor, enabled: bool) {
        if monitor.dpms_status != enabled {
            self.dpms(&monitor.name, enabled);
        }
    }

    fn dpms(&self, connector: &str, enabled: bool) {
        if enabled
            && connector == INTERNAL
            && (lid_state() == Lid::Closed || self.override_active())
        {
            return;
        }
        let command = format!(
            "hl.dsp.dpms({{ action = {}, monitor = {} }})",
            lua_string(if enabled { "enable" } else { "disable" }),
            lua_string(connector)
        );
        if let Err(error) = self.hyprland.dispatch(&command) {
            eprintln!("wave display: {error:#}");
        }
    }

    /// Hides the flash of moving workspaces behind Quickshell's blackout.
    fn blackout(&self) {
        let mut command = std::process::Command::new("qs");
        command
            .args(["-c", "wave", "ipc", "call", "blackout", "trigger"])
            .stderr(std::process::Stdio::null());
        match crate::process::capture(&mut command, Duration::from_secs(2)) {
            Ok(output) if output.success() => std::thread::sleep(BLACKOUT_SETTLE),
            Ok(output) => eprintln!("wave display: blackout failed ({})", output.code),
            Err(error) => eprintln!("wave display: blackout failed: {error:#}"),
        }
    }

    /// The keyboard backlight goes dark with the laptop screen; the level it
    /// had is kept in the session state so a daemon restart still restores it.
    fn darken_keyboard(&mut self) {
        if self.ownership.state.keyboard_backlight.is_some() {
            return;
        }
        let Some(level) = keyboard_backlight() else {
            return;
        };
        self.ownership.state.keyboard_backlight = Some(level);
        if level > 0 {
            set_keyboard_backlight(0);
        }
    }

    fn restore_keyboard(&mut self) {
        if let Some(level) = self.ownership.state.keyboard_backlight.take()
            && level > 0
        {
            set_keyboard_backlight(level);
        }
    }

    fn stop_dim(&self) {
        if let Err(error) = self.logind.stop_user_unit("wave-dim.service") {
            eprintln!("wave display: cannot stop wave-dim: {error:#}");
        }
    }

    fn defer_sleep(&mut self) {
        self.suspend_retry_at = Some(Instant::now() + self.suspend_delay);
        self.suspend_delay =
            (self.suspend_delay * 2).clamp(Duration::from_secs(1), Duration::from_secs(30));
    }

    fn reset_sleep_retry(&mut self) {
        self.suspend_retry_at = None;
        self.suspend_delay = Duration::from_secs(1);
    }

    fn request_sleep(&mut self, idle: bool) {
        if self.suspend_requested
            || self
                .suspend_retry_at
                .is_some_and(|due| Instant::now() < due)
        {
            return;
        }
        if self.logind.sleep_inhibited(idle) {
            self.defer_sleep();
            return;
        }
        match self.logind.sleep() {
            Ok(operation) => {
                eprintln!("wave display: {operation} requested");
                self.suspend_requested = true;
                self.reset_sleep_retry();
            }
            Err(error) => {
                eprintln!("wave display: sleep request failed: {error:#}");
                self.defer_sleep();
            }
        }
    }

    /// With a usable display, sleep only for a pending idle request.
    fn settle_sleep(&mut self) {
        if self.idle_requested {
            self.request_sleep(true);
        } else {
            self.reset_sleep_retry();
        }
    }
}
