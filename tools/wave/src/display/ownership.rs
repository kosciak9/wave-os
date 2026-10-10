use super::hyprland::Monitor;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::time::{Duration, Instant};

/// How long Hyprland may take to emit the follow-up events of one change.
pub const EVENT_DELAY: Duration = Duration::from_millis(200);
/// Moves onto an output this soon after it appeared are Hyprland restoring it.
const ADDED_OUTPUT_GRACE: Duration = Duration::from_secs(2);

/// Session state kept across daemon restarts within one Hyprland instance.
#[derive(Default, Serialize, Deserialize)]
pub struct State {
    #[serde(default)]
    pub workspaces: BTreeMap<i64, WorkspaceRecord>,
    /// Output identity -> the workspace last active on it.
    #[serde(default)]
    pub last_active: BTreeMap<String, i64>,
    #[serde(default)]
    pub preferred_external: String,
    /// Hyprland instance signature the lid override was set in; another
    /// instance means a new session, which starts without the override.
    #[serde(default)]
    pub lid_override: Option<String>,
    /// Keyboard backlight level to restore once the laptop screen is back
    /// and undimmed.
    #[serde(default)]
    pub keyboard_backlight: Option<u8>,
    /// Laptop screen backlight before the idle dim, restored on activity.
    #[serde(default)]
    pub dimmed_backlight: Option<Backlight>,
}

#[derive(Clone, Serialize, Deserialize)]
pub struct Backlight {
    pub device: String,
    pub brightness: u32,
}

#[derive(Default, Serialize, Deserialize)]
pub struct WorkspaceRecord {
    #[serde(default)]
    pub current_connector: String,
    /// Output identity the user last placed the workspace on.
    #[serde(default)]
    pub desired_identity: Option<String>,
}

struct PendingMove {
    old_connector: String,
    destination: String,
    when: Instant,
    generated: bool,
}

/// A description identifies a physical display across connectors; commas are
/// dropped because Hyprland events separate fields with them.
pub fn description_identity(description: &str) -> Option<String> {
    let value = description
        .replace(',', " ")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    (!value.is_empty()).then(|| format!("description:{value}"))
}

fn connector_identity(connector: &str) -> String {
    format!("connector:{connector}")
}

/// Workspace placement bookkeeping: which moves the user made (and should
/// be restored after topology changes) versus which Hyprland or we caused.
#[derive(Default)]
pub struct Ownership {
    pub state: State,
    pending: HashMap<i64, PendingMove>,
    removed_connectors: HashSet<String>,
    added_at: HashMap<String, Instant>,
    /// Live outputs only; history must never make a disconnected output
    /// look like a restoration target.
    connector_to_identity: HashMap<String, String>,
    identity_to_connector: HashMap<String, String>,
}

impl Ownership {
    pub fn new(state: State) -> Self {
        Self {
            state,
            ..Self::default()
        }
    }

    pub fn map_outputs(&mut self, monitors: &[Monitor]) {
        let mut description_count: HashMap<String, usize> = HashMap::new();
        for monitor in monitors {
            if let Some(identity) = description_identity(&monitor.description) {
                *description_count.entry(identity).or_default() += 1;
            }
        }
        self.connector_to_identity.clear();
        self.identity_to_connector.clear();
        for monitor in monitors {
            let identity = description_identity(&monitor.description)
                .filter(|identity| description_count[identity] == 1)
                .unwrap_or_else(|| connector_identity(&monitor.name));
            self.connector_to_identity
                .insert(monitor.name.clone(), identity.clone());
            self.identity_to_connector
                .insert(identity, monitor.name.clone());
        }
    }

    pub fn identity_of(&self, connector: &str) -> String {
        self.connector_to_identity
            .get(connector)
            .cloned()
            .unwrap_or_else(|| connector_identity(connector))
    }

    pub fn connector_of(&self, identity: &str) -> Option<&str> {
        self.identity_to_connector.get(identity).map(String::as_str)
    }

    pub fn connected(&self) -> impl Iterator<Item = &str> {
        self.connector_to_identity.keys().map(String::as_str)
    }

    pub fn record(&mut self, id: i64) -> &mut WorkspaceRecord {
        self.state.workspaces.entry(id).or_default()
    }

    pub fn move_event(&mut self, id: i64, destination: &str, generated: bool) {
        if id <= 0 {
            return;
        }
        let record = self.record(id);
        let old_connector = std::mem::replace(&mut record.current_connector, destination.into());
        let restoring = self
            .added_at
            .get(destination)
            .is_some_and(|added| added.elapsed() < ADDED_OUTPUT_GRACE);
        self.pending.insert(
            id,
            PendingMove {
                old_connector,
                destination: destination.into(),
                when: Instant::now(),
                generated: generated || restoring,
            },
        );
    }

    pub fn monitor_removed(&mut self, connector: &str) {
        self.removed_connectors.insert(connector.into());
        // Hyprland evacuates workspaces before announcing the removal; a quick
        // re-add must not turn that evacuation into a user move.
        for pending in self.pending.values_mut() {
            if pending.old_connector == connector {
                pending.generated = true;
            }
        }
        for record in self.state.workspaces.values_mut() {
            if record.current_connector == connector {
                record.current_connector.clear();
            }
        }
    }

    pub fn monitor_added(&mut self, connector: &str, identity: Option<&str>) {
        self.removed_connectors.remove(connector);
        self.added_at.insert(connector.into(), Instant::now());
        let Some(identity) = identity else { return };
        for (id, pending) in &mut self.pending {
            let desired = self
                .state
                .workspaces
                .get(id)
                .and_then(|record| record.desired_identity.as_deref());
            if pending.destination == connector && desired == Some(identity) {
                pending.generated = true;
            }
        }
    }

    pub fn destroy_workspace(&mut self, id: i64) {
        self.state.workspaces.remove(&id);
        self.state.last_active.retain(|_, active| *active != id);
        self.pending.remove(&id);
    }

    /// Settles moves old enough that no follow-up event can reclassify them.
    pub fn flush(&mut self) {
        let settled: Vec<i64> = self
            .pending
            .iter()
            .filter(|(_, pending)| pending.when.elapsed() >= EVENT_DELAY)
            .map(|(id, _)| *id)
            .collect();
        for id in settled {
            let pending = self.pending.remove(&id).expect("settled move is pending");
            let automatic = self.removed_connectors.contains(&pending.old_connector);
            if !automatic && !pending.generated {
                let identity = self.identity_of(&pending.destination);
                self.record(id).desired_identity = Some(identity);
            }
        }
    }

    pub fn next_flush(&self) -> Option<Instant> {
        self.pending
            .values()
            .map(|pending| pending.when + EVENT_DELAY)
            .min()
    }
}
