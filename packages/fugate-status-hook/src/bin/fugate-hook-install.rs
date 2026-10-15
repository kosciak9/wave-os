//! Merges the Fugate Stop hook into Claude and Codex hook settings and records
//! Codex trust for it and for Herdr's Codex hooks.

use std::collections::HashSet;
use std::env;
use std::error::Error;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process;

use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};

type Result<T> = std::result::Result<T, Box<dyn Error>>;

// Mirrors Codex 0.162 hook trust identities (hooks/src/engine/discovery.rs).
const EVENT_LABELS: [(&str, &str); 12] = [
    ("PreToolUse", "pre_tool_use"),
    ("PermissionRequest", "permission_request"),
    ("PostToolUse", "post_tool_use"),
    ("PreCompact", "pre_compact"),
    ("PostCompact", "post_compact"),
    ("SessionStart", "session_start"),
    ("SessionEnd", "session_end"),
    ("UserPromptSubmit", "user_prompt_submit"),
    ("SubagentStart", "subagent_start"),
    ("SubagentStop", "subagent_stop"),
    ("Stop", "stop"),
    ("Interrupt", "interrupt"),
];
const MATCHERLESS_EVENTS: [&str; 3] = ["UserPromptSubmit", "Stop", "Interrupt"];
const SHORT_TIMEOUT_EVENTS: [&str; 2] = ["SessionEnd", "Interrupt"];
const CONTEXT_EVENTS: [&str; 5] = [
    "PreToolUse",
    "PostToolUse",
    "SessionStart",
    "UserPromptSubmit",
    "SubagentStart",
];
const DEFAULT_CONTEXT_LIMIT: f64 = 2500.0;

/// Recognizes the command hooks this installer manages.
struct ManagedCommands {
    current: String,
    store_dir: String,
    herdr_prefix: String,
}

impl ManagedCommands {
    fn new(current: String, store_dir: String, codex_home: &Path) -> Self {
        // Herdr's `integration install codex` always single-quotes the script path.
        let script = codex_home.join("herdr-agent-state.sh");
        let quoted = script.to_string_lossy().replace('\'', "'\"'\"'");
        Self {
            current,
            store_dir,
            herdr_prefix: format!("bash '{quoted}' "),
        }
    }

    /// Any generation of this hook; generations differ only in their store hash.
    fn is_ours(&self, command: &str) -> bool {
        let Some(rest) = command
            .strip_prefix(self.store_dir.as_str())
            .and_then(|rest| rest.strip_prefix('/'))
            .and_then(|rest| rest.strip_suffix("/bin/fugate-status-hook"))
        else {
            return false;
        };
        let Some((hash, name)) = rest.split_at_checked(32) else {
            return false;
        };
        hash.bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit())
            && name
                .strip_prefix("-fugate-status-hook-")
                .is_some_and(|version| !version.is_empty() && !version.contains('/'))
    }

    fn is_herdr(&self, command: &str) -> bool {
        command
            .strip_prefix(self.herdr_prefix.as_str())
            .is_some_and(|state| {
                !state.is_empty() && state.bytes().all(|byte| byte.is_ascii_lowercase())
            })
    }

    fn is_stale(&self, hook: &Value) -> bool {
        let command = hook.get("command").and_then(Value::as_str);
        command.is_some_and(|command| command != self.current && self.is_ours(command))
    }

    /// Trust keys and hashes of our and Herdr's command hooks in a hooks file.
    fn trust_entries(&self, settings: &Value, hooks_path: &str) -> Result<Vec<(String, String)>> {
        let mut entries = Vec::new();
        let Some(events) = settings.get("hooks").and_then(Value::as_object) else {
            return Ok(entries);
        };
        for (event, groups) in events {
            let Some(&(_, label)) = EVENT_LABELS.iter().find(|(name, _)| name == event) else {
                continue;
            };
            for (group_index, group) in groups.as_array().into_iter().flatten().enumerate() {
                let handlers = group.get("hooks").and_then(Value::as_array);
                for (handler_index, hook) in handlers.into_iter().flatten().enumerate() {
                    let Some(command) = hook.get("command").and_then(Value::as_str) else {
                        continue;
                    };
                    if hook.get("type").and_then(Value::as_str) == Some("command")
                        && (self.is_ours(command) || self.is_herdr(command))
                    {
                        entries.push((
                            format!("{hooks_path}:{label}:{group_index}:{handler_index}"),
                            trust_hash(event, label, group.get("matcher"), hook, command)?,
                        ));
                    }
                }
            }
        }
        Ok(entries)
    }
}

fn main() {
    if let Err(error) = run() {
        eprintln!("Fugate: {error}");
        process::exit(1);
    }
}

fn run() -> Result<()> {
    let [command, store_dir, claude_settings, codex_home]: [String; 4] = env::args()
        .skip(1)
        .collect::<Vec<_>>()
        .try_into()
        .map_err(|_| "usage: fugate-hook-install HOOK STORE_DIR CLAUDE_SETTINGS CODEX_HOME")?;
    let codex_home = PathBuf::from(codex_home);
    let managed = ManagedCommands::new(command, store_dir, &codex_home);

    install_stop_hook(Path::new(&claude_settings), &managed)?;
    let codex_hooks = codex_home.join("hooks.json");
    let (previous, settings) = install_stop_hook(&codex_hooks, &managed)?;
    // Codex keys trust by the resolved hooks.json path.
    let hooks_path = fs::canonicalize(&codex_hooks)?;
    let hooks_path = hooks_path.to_str().ok_or("hooks.json path is not UTF-8")?;
    trust_codex_hooks(
        &codex_home.join("config.toml"),
        hooks_path,
        &managed,
        &previous,
        &settings,
    )
}

/// Keeps exactly one Stop entry of the current hook; returns the settings before and after.
fn install_stop_hook(path: &Path, managed: &ManagedCommands) -> Result<(Value, Value)> {
    let original: Value = match read_optional(path)? {
        Some(text) => serde_json::from_str(&text)?,
        None => json!({}),
    };
    let mut settings = original.clone();
    let invalid = || format!("{} has no hooks.Stop array", path.display());
    let groups = settings
        .as_object_mut()
        .ok_or_else(invalid)?
        .entry("hooks")
        .or_insert_with(|| json!({}))
        .as_object_mut()
        .ok_or_else(invalid)?
        .entry("Stop")
        .or_insert_with(|| json!([]))
        .as_array_mut()
        .ok_or_else(invalid)?;
    groups.retain_mut(|group| {
        let Some(handlers) = group.get_mut("hooks").and_then(Value::as_array_mut) else {
            return true;
        };
        let count = handlers.len();
        handlers.retain(|hook| !managed.is_stale(hook));
        handlers.len() == count || !handlers.is_empty()
    });
    // Codex keys hook trust by position, so a present entry stays put.
    let present = groups.iter().any(|group| {
        let handlers = group.get("hooks").and_then(Value::as_array);
        handlers.into_iter().flatten().any(|hook| {
            hook.get("command").and_then(Value::as_str) == Some(managed.current.as_str())
        })
    });
    if !present {
        groups.push(json!({
            "hooks": [{"type": "command", "command": managed.current, "timeout": 5}]
        }));
    }
    if settings != original {
        write_atomically(path, &(serde_json::to_string_pretty(&settings)? + "\n"))?;
    }
    Ok((original, settings))
}

/// Codex hook_hash: SHA-256 of the sorted, compact JSON of the normalized hook.
fn trust_hash(
    event: &str,
    label: &str,
    matcher: Option<&Value>,
    hook: &Value,
    command: &str,
) -> Result<String> {
    let timeout = match hook.get("timeout") {
        None | Some(Value::Null) => None,
        Some(timeout) => Some(timeout.as_i64().ok_or("hook timeout must be an integer")?),
    };
    let timeout = if SHORT_TIMEOUT_EVENTS.contains(&event) {
        timeout.unwrap_or(1).clamp(1, 3)
    } else {
        timeout.unwrap_or(600).max(1)
    };
    let mut normalized = Map::new();
    normalized.insert("type".into(), "command".into());
    normalized.insert("command".into(), command.into());
    normalized.insert("timeout".into(), timeout.into());
    normalized.insert(
        "async".into(),
        hook.get("async").cloned().unwrap_or(false.into()),
    );
    if let Some(status_message) = hook.get("statusMessage") {
        normalized.insert("statusMessage".into(), status_message.clone());
    }
    let context_limit = hook
        .get("additionalContextLimit")
        .filter(|limit| !limit.is_null() && limit.as_f64() != Some(DEFAULT_CONTEXT_LIMIT));
    if let (true, Some(limit)) = (CONTEXT_EVENTS.contains(&event), context_limit) {
        normalized.insert("additionalContextLimit".into(), limit.clone());
    }
    let mut identity = json!({"event_name": label, "hooks": [normalized]});
    if let (false, Some(matcher)) = (
        MATCHERLESS_EVENTS.contains(&event),
        matcher.filter(|matcher| !matcher.is_null()),
    ) {
        identity["matcher"] = matcher.clone();
    }
    identity.sort_all_objects();
    let digest = Sha256::digest(serde_json::to_string(&identity)?);
    let hex: String = digest.iter().map(|byte| format!("{byte:02x}")).collect();
    Ok(format!("sha256:{hex}"))
}

fn hook_states(config: &toml::Table) -> toml::Table {
    config
        .get("hooks")
        .and_then(|hooks| hooks.get("state"))
        .and_then(toml::Value::as_table)
        .cloned()
        .unwrap_or_default()
}

fn without_hook_states(mut config: toml::Table) -> toml::Table {
    if let Some(hooks) = config.get_mut("hooks").and_then(toml::Value::as_table_mut) {
        hooks.remove("state");
        if hooks.is_empty() {
            config.remove("hooks");
        }
    }
    config
}

/// Trusts managed hooks where they are and drops their trust at positions they left.
fn trust_codex_hooks(
    config_path: &Path,
    hooks_path: &str,
    managed: &ManagedCommands,
    previous_settings: &Value,
    settings: &Value,
) -> Result<()> {
    let desired = managed.trust_entries(settings, hooks_path)?;
    let mut managed_hashes: HashSet<String> =
        desired.iter().map(|(_, hash)| hash.clone()).collect();
    managed_hashes.extend(
        managed
            .trust_entries(previous_settings, hooks_path)?
            .into_iter()
            .map(|(_, hash)| hash),
    );
    let is_desired = |key: &str| desired.iter().any(|(desired_key, _)| desired_key == key);
    let refusal = |reason: &str| format!("refusing to write {}: {reason}", config_path.display());

    let text = read_optional(config_path)?.unwrap_or_default();
    let original: toml::Table = toml::from_str(&text)?;
    let current = hook_states(&original);
    let mut expected = current.clone();
    let prefix = format!("{hooks_path}:");
    for (key, state) in expected.iter_mut() {
        let Some(state) = state.as_table_mut() else {
            continue;
        };
        let trusted = state.get("trusted_hash").and_then(toml::Value::as_str);
        if !is_desired(key)
            && key.starts_with(&prefix)
            && trusted.is_some_and(|hash| managed_hashes.contains(hash))
        {
            state.remove("trusted_hash");
        }
    }
    for (key, trusted) in &desired {
        expected
            .entry(key.as_str())
            .or_insert_with(|| toml::Table::new().into())
            .as_table_mut()
            .ok_or_else(|| refusal("a hook state is not a table"))?
            .insert("trusted_hash".into(), trusted.as_str().into());
    }
    expected.retain(|_, state| state.as_table().is_none_or(|state| !state.is_empty()));
    if expected == current {
        return Ok(());
    }

    let not_standard = || refusal("hooks and hooks.state must be standard tables");
    let mut document: toml_edit::DocumentMut = text.parse()?;
    let table = document
        .entry("hooks")
        .or_insert_with(implicit_table)
        .as_table_mut()
        .ok_or_else(not_standard)?
        .entry("state")
        .or_insert_with(implicit_table)
        .as_table_mut()
        .ok_or_else(not_standard)?;
    table.retain(|key, _| expected.contains_key(key));
    for (key, _) in &desired {
        if !table.contains_key(key) {
            table.insert(key, toml_edit::table());
        }
    }
    for (key, state) in &expected {
        let entry = table
            .get_mut(key)
            .and_then(toml_edit::Item::as_table_like_mut)
            .ok_or_else(|| refusal("a hook state is not a table"))?;
        let previous = current.get(key).and_then(|state| state.get("trusted_hash"));
        match state.get("trusted_hash") {
            None => {
                entry.remove("trusted_hash");
            }
            Some(trusted) if previous != Some(trusted) => {
                let trusted = trusted
                    .as_str()
                    .ok_or_else(|| refusal("trusted_hash is not a string"))?;
                entry.insert("trusted_hash", toml_edit::value(trusted));
            }
            Some(_) => {}
        }
    }

    let updated = document.to_string();
    let preserved = toml::from_str::<toml::Table>(&updated).is_ok_and(|parsed| {
        hook_states(&parsed) == expected
            && without_hook_states(parsed) == without_hook_states(original)
    });
    if !preserved {
        return Err(refusal("the edit would change more than hook trust state.").into());
    }
    write_atomically(config_path, &updated)
}

fn implicit_table() -> toml_edit::Item {
    let mut table = toml_edit::Table::new();
    table.set_implicit(true);
    toml_edit::Item::Table(table)
}

fn read_optional(path: &Path) -> Result<Option<String>> {
    match fs::read_to_string(path) {
        Ok(text) => Ok(Some(text)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error.into()),
    }
}

/// Replaces the symlink target in place, keeping the original file's permissions.
fn write_atomically(path: &Path, contents: &str) -> Result<()> {
    let target = fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    let name = target
        .file_name()
        .ok_or("cannot write a path without a file name")?;
    let temporary =
        target.with_file_name(format!(".{}.{}.tmp", name.to_string_lossy(), process::id()));
    let written = (|| -> io::Result<()> {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)?;
        if let Ok(metadata) = fs::metadata(&target) {
            file.set_permissions(metadata.permissions())?;
        }
        file.write_all(contents.as_bytes())?;
        file.sync_all()?;
        fs::rename(&temporary, &target)
    })();
    if written.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    Ok(written?)
}
