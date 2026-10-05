use anyhow::{bail, Context, Result};
use rusqlite::{params, Connection, OpenFlags, OptionalExtension};
use serde_json::{json, Value};
use std::{
    fs::{DirBuilder, Metadata, OpenOptions},
    os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

#[derive(Clone)]
pub struct Store {
    connection: Arc<Mutex<Connection>>,
    path: Arc<PathBuf>,
    identity: (u64, u64),
}

#[derive(Debug)]
pub struct ProjectionError(pub String);

impl std::fmt::Display for ProjectionError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}
impl std::error::Error for ProjectionError {}

fn private_metadata(path: &Path, directory: bool) -> Result<Metadata> {
    let metadata = std::fs::symlink_metadata(path)?;
    let owned = metadata.uid() == unsafe { libc::geteuid() };
    let correct_type = if directory {
        metadata.is_dir()
    } else {
        metadata.is_file() && metadata.nlink() == 1
    };
    if !owned || !correct_type || metadata.file_type().is_symlink() || metadata.mode() & 0o077 != 0
    {
        bail!("mirror storage must be owned, private, and nonsymlinked (files must have one link)");
    }
    Ok(metadata)
}

fn validate_storage(path: &Path, identity: Option<(u64, u64)>) -> Result<Metadata> {
    private_metadata(
        path.parent()
            .context("database requires a containing directory")?,
        true,
    )?;
    let metadata = private_metadata(path, false)?;
    if identity.is_some_and(|identity| identity != (metadata.dev(), metadata.ino())) {
        bail!("mirror database identity changed");
    }
    for suffix in ["-wal", "-shm", "-journal"] {
        let mut sidecar = path.as_os_str().to_os_string();
        sidecar.push(suffix);
        match std::fs::symlink_metadata(&sidecar) {
            Ok(_) => {
                private_metadata(Path::new(&sidecar), false)?;
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(e.into()),
        }
    }
    Ok(metadata)
}

pub fn now_ms() -> i64 {
    chrono::Utc::now().timestamp_millis()
}

impl Store {
    pub fn open(path: &Path) -> Result<Self> {
        let path = if path.is_absolute() {
            path.to_owned()
        } else {
            std::env::current_dir()?.join(path)
        };
        let parent = path
            .parent()
            .context("database requires a containing directory")?;
        if !parent.try_exists()? {
            DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(parent)?;
        }
        private_metadata(parent, true)?;
        // macOS /var is a system symlink; resolve ancestors, never the database itself.
        let path = std::fs::canonicalize(parent)?
            .join(path.file_name().context("database requires a filename")?);
        match std::fs::symlink_metadata(&path) {
            Ok(_) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .mode(0o600)
                    .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
                    .open(&path)?;
            }
            Err(e) => return Err(e.into()),
        }
        let metadata = validate_storage(&path, None)?;
        let identity = (metadata.dev(), metadata.ino());
        let mut connection = Connection::open_with_flags(
            &path,
            OpenFlags::SQLITE_OPEN_READ_WRITE
                | OpenFlags::SQLITE_OPEN_NO_MUTEX
                | OpenFlags::SQLITE_OPEN_NOFOLLOW,
        )?;
        validate_storage(&path, Some(identity))?;
        connection.busy_timeout(Duration::from_secs(10))?;
        let version: i64 = connection.pragma_query_value(None, "user_version", |r| r.get(0))?;
        if version > 1 {
            bail!("mirror schema {version} is newer than supported schema 1");
        }
        connection.pragma_update(None, "journal_mode", "WAL")?;
        let tx = connection.transaction()?;
        tx.execute_batch(SCHEMA)?;
        if version == 0 {
            tx.execute_batch("DELETE FROM messages_fts; INSERT INTO messages_fts(rowid,text,channel_id,ts) SELECT rowid,text,channel_id,ts FROM messages WHERE deleted=0;")?;
        }
        tx.pragma_update(None, "user_version", 1)?;
        tx.commit()?;
        validate_storage(&path, Some(identity))?;
        Ok(Self {
            connection: Arc::new(Mutex::new(connection)),
            path: Arc::new(path),
            identity,
        })
    }

    pub fn with_conn<T>(&self, f: impl FnOnce(&mut Connection) -> Result<T>) -> Result<T> {
        let mut connection = self
            .connection
            .lock()
            .map_err(|_| anyhow::anyhow!("mirror database mutex poisoned"))?;
        f(&mut connection)
    }

    pub fn with_reader<T>(&self, f: impl FnOnce(&mut Connection) -> Result<T>) -> Result<T> {
        let deadline = Instant::now() + Duration::from_secs(2);
        validate_storage(&self.path, Some(self.identity))?;
        let mut connection = Connection::open_with_flags(
            &*self.path,
            OpenFlags::SQLITE_OPEN_READ_ONLY
                | OpenFlags::SQLITE_OPEN_NO_MUTEX
                | OpenFlags::SQLITE_OPEN_NOFOLLOW,
        )?;
        validate_storage(&self.path, Some(self.identity))?;
        connection.busy_timeout(deadline.saturating_duration_since(Instant::now()))?;
        connection.progress_handler(1000, Some(move || Instant::now() >= deadline));
        connection.pragma_update(None, "query_only", true)?;
        if Instant::now() >= deadline {
            bail!("mirror query deadline exceeded");
        }
        f(&mut connection)
    }

    pub fn meta(&self, key: &str) -> Result<Option<String>> {
        self.with_conn(|c| {
            Ok(
                c.query_row("SELECT value FROM meta WHERE key=?1", [key], |r| r.get(0))
                    .optional()?,
            )
        })
    }

    pub fn set_meta(&self, key: &str, value: &str) -> Result<()> {
        // Metadata is operational state; session credentials belong only in memory.
        if secret_key(key) || credential_value(value) {
            bail!("credential metadata is not permitted");
        }
        self.with_conn(|c| { c.execute("INSERT INTO meta(key,value) VALUES(?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value", params![key,value])?; Ok(()) })
    }

    pub fn upsert_conversation(&self, value: &Value) -> Result<()> {
        self.with_conn(|c| {
            let tx = c.transaction()?;
            conversation(&tx, value)?;
            tx.commit()?;
            Ok(())
        })
    }

    pub fn upsert_user(&self, value: &Value) -> Result<()> {
        self.with_conn(|c| {
            let tx = c.transaction()?;
            user(&tx, value)?;
            tx.commit()?;
            Ok(())
        })
    }

    pub fn upsert_message(&self, channel: &str, value: &Value) -> Result<()> {
        self.with_conn(|c| {
            let tx = c.transaction()?;
            message(&tx, channel, value)?;
            tx.commit()?;
            Ok(())
        })
    }

    pub fn apply_event(&self, envelope: &Value) -> Result<()> {
        self.with_conn(|c| {
            let tx = c.transaction()?;
            let event = envelope.get("event").filter(|e| e.is_object()).unwrap_or(envelope);
            let kind = string(event, "type");
            tx.execute("INSERT INTO events(received_at,event_type,raw) VALUES(?1,?2,?3)", params![now_ms(),kind,clean(envelope).to_string()])?;
            let sequence=tx.last_insert_rowid();
            // Retain the event even when an unexpected payload cannot be projected.
            tx.execute_batch("SAVEPOINT event_projection")?;
            let projection = (|| -> Result<()> {
            let channel = event.get("channel").and_then(Value::as_str).unwrap_or("");
            match kind {
                "message" => match string(event, "subtype") {
                    "message_deleted" => {
                        validate_channel(channel)?;
                        let ts = required(event, "deleted_ts")?;
                        validate_timestamp(ts)?;
                        if let Some(previous) = event.get("previous_message") { message(&tx, channel, previous)?; }
                        let old: Option<String> = tx.query_row("SELECT raw FROM messages WHERE channel_id=?1 AND ts=?2 AND deleted=0", params![channel,ts], |r| r.get(0)).optional()?;
                        if let Some(raw) = old { save_edit(&tx, channel, ts, &raw)?; }
                        tx.execute("INSERT INTO messages(channel_id,ts,raw,deleted) VALUES(?1,?2,?3,1) ON CONFLICT(channel_id,ts) DO UPDATE SET deleted=1", params![channel,ts,json!({"ts":ts}).to_string()])?;
                    }
                    "message_changed" | "message_replied" => {
                        if let Some(previous) = event.get("previous_message") { message(&tx, channel, previous)?; }
                        let value=event.get("message").filter(|v|v.is_object()).ok_or_else(||ProjectionError("missing message object".into()))?;
                        message(&tx,channel,value)?;
                    }
                    "channel_topic" | "channel_purpose" | "channel_name" => {
                        message(&tx,channel,event)?;
                        let field = match string(event,"subtype") { "channel_topic"=>"topic", "channel_purpose"=>"purpose", _=>"name" };
                        if let Some(value)=event.get(field) {
                            let mut patch=json!({"id":channel});
                            patch[field]=if field=="name" {value.clone()} else {json!({"value":value})};
                            conversation(&tx,&patch)?;
                        }
                    }
                    _ => message(&tx, channel, event)?,
                },
                "reaction_added" | "reaction_removed" => {
                    let item = &event["item"];
                    if string(item,"type") == "message" {
                        let ch = required(item,"channel")?;
                        let ts = required(item,"ts")?;
                        validate_channel(ch)?;
                        validate_timestamp(ts)?;
                        let name = required(event,"reaction")?;
                        let uid = required(event,"user")?;
                        if kind == "reaction_added" {
                            tx.execute("INSERT OR IGNORE INTO reactions(channel_id,ts,name,user_id) VALUES(?1,?2,?3,?4)",params![ch,ts,name,uid])?;
                        } else {
                            tx.execute("DELETE FROM reactions WHERE channel_id=?1 AND ts=?2 AND name=?3 AND user_id=?4",params![ch,ts,name,uid])?;
                        }
                        record_sequence(&tx,&format!("event_reactions:{ch}:{ts}"),sequence)?;
                    }
                }
                "user_change" | "team_join" => { if event["user"].is_object() { user(&tx,&event["user"])?; } }
                    "channel_created" | "group_created" | "im_created" | "mpim_created" | "channel_rename" | "group_rename" | "channel_joined" | "group_joined" | "channel_change" | "group_change" => {
                    if event["channel"].is_object() { conversation(&tx,&event["channel"])?; }
                }
                "channel_archive" | "group_archive" | "channel_unarchive" | "group_unarchive" | "channel_left" | "group_left" => {
                    if !channel.is_empty() {
                        let patch = if kind.ends_with("left") { json!({"id":channel,"is_member":false}) } else { json!({"id":channel,"is_archived":!kind.ends_with("unarchive")}) };
                        conversation(&tx,&patch)?;
                    }
                }
                "channel_marked" | "group_marked" | "im_marked" | "mpim_marked" | "channel_history_changed" => {
                    validate_channel(channel)?;
                    channel_read(&tx,channel,event)?;
                    record_sequence(&tx,&format!("event_read:{channel}"),sequence)?;
                }
                "thread_marked" | "thread_subscribed" | "thread_unsubscribed" => {
                    let ch = event.get("channel").and_then(Value::as_str).or_else(|| event["subscription"]["channel"].as_str()).unwrap_or("");
                    let root = event.get("thread_ts").and_then(Value::as_str).or_else(|| event["subscription"]["thread_ts"].as_str()).unwrap_or("");
                    validate_channel(ch)?;
                    validate_timestamp(root)?;
                    {
                        let mut patch = event.clone();
                        if let Some(subscription) = event.get("subscription") { merge(&mut patch,subscription); }
                        if kind != "thread_marked" { patch["subscribed"] = json!(kind == "thread_subscribed"); }
                        else if patch.get("last_read").is_none() { patch["last_read"]=json!(required(event,"ts")?); }
                        thread_read(&tx,ch,root,&patch)?;
                        record_sequence(&tx,&format!("event_thread_read:{ch}:{root}"),sequence)?;
                    }
                }
                "file_created" | "file_shared" | "file_change" => { if event["file"].is_object() { file(&tx,&event["file"])?; } }
                "file_deleted" => {
                    if let Some(id) = event.get("file_id").and_then(Value::as_str).or_else(|| event.get("file").and_then(Value::as_str)) {
                        tx.execute("INSERT INTO files(id,raw,deleted) VALUES(?1,'{}',1) ON CONFLICT(id) DO UPDATE SET deleted=1",[id])?;
                    }
                }
                _ => {}
            }
            Ok(())
            })();
            if projection.is_err() { tx.execute_batch("ROLLBACK TO event_projection")?; }
            tx.execute_batch("RELEASE event_projection")?;
            let projection = match projection {
                Err(error) if error.downcast_ref::<ProjectionError>().is_some() => {
                    // ProjectionError messages contain field names only, never payload values.
                    let message=error.downcast_ref::<ProjectionError>().unwrap().to_string();
                    tx.execute("INSERT INTO meta(key,value) VALUES('projection_error',?1) ON CONFLICT(key) DO UPDATE SET value=excluded.value",[message])?;
                    Ok(())
                }
                result => result,
            };
            tx.commit()?;
            projection
        })
    }
}

fn string<'a>(value: &'a Value, key: &str) -> &'a str {
    value.get(key).and_then(Value::as_str).unwrap_or("")
}
fn required<'a>(value: &'a Value, key: &str) -> Result<&'a str> {
    value
        .get(key)
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| ProjectionError(format!("missing or invalid {key}")).into())
}
fn validate_channel(channel: &str) -> Result<()> {
    if channel.len() < 2
        || channel.len() > 64
        || !matches!(channel.as_bytes()[0], b'C' | b'G' | b'D')
        || !channel.bytes().all(|b| b.is_ascii_alphanumeric())
    {
        return Err(ProjectionError("invalid channel id".into()).into());
    }
    Ok(())
}
fn validate_timestamp(ts: &str) -> Result<()> {
    if ts.len() != 17
        || !ts.bytes().enumerate().all(|(i, b)| {
            if i == 10 {
                b == b'.'
            } else {
                b.is_ascii_digit()
            }
        })
    {
        return Err(ProjectionError("invalid Slack timestamp".into()).into());
    }
    Ok(())
}
fn record_sequence(c: &Connection, key: &str, sequence: i64) -> Result<()> {
    c.execute("INSERT INTO meta(key,value) VALUES(?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value",params![key,sequence.to_string()])?;
    Ok(())
}
fn snapshot_patch(c: &Connection, patch: &Value, key: &str, fields: &[&str]) -> Result<Value> {
    let mut patch = patch.clone();
    if let Some(snapshot) = patch.get("__mirror_snapshot_event_id") {
        let snapshot = snapshot
            .as_i64()
            .filter(|id| *id >= 0)
            .ok_or_else(|| ProjectionError("invalid mirror snapshot event id".into()))?;
        let sequence: Option<String> = c
            .query_row("SELECT value FROM meta WHERE key=?1", [key], |r| r.get(0))
            .optional()?;
        if sequence
            .map(|id| id.parse::<i64>())
            .transpose()
            .context("invalid stored event sequence")?
            .is_some_and(|id| id > snapshot)
        {
            if let Some(object) = patch.as_object_mut() {
                for field in fields {
                    object.remove(*field);
                }
            }
        }
    }
    Ok(patch)
}
fn secret_key(key: &str) -> bool {
    let k = key.to_ascii_lowercase();
    k.contains("token")
        || k.contains("cookie")
        || k.contains("password")
        || k.contains("secret")
        || k.contains("authorization")
        || k.contains("credential")
        || k == "session"
        || k == "session_data"
}
fn credential_value(value: &str) -> bool {
    let lower = value.to_ascii_lowercase();
    [
        "xoxb-",
        "xoxp-",
        "xoxc-",
        "xoxd-",
        "xapp-",
        "bearer ",
        "cookie:",
        "authorization:",
    ]
    .iter()
    .any(|needle| lower.contains(needle))
}
fn clean(value: &Value) -> Value {
    match value {
        Value::Object(map) => Value::Object(
            map.iter()
                .filter(|(k, _)| !secret_key(k) && k.as_str() != "__mirror_snapshot_event_id")
                .map(|(k, v)| (k.clone(), clean(v)))
                .collect(),
        ),
        Value::Array(values) => Value::Array(values.iter().map(clean).collect()),
        _ => value.clone(),
    }
}
fn merge(target: &mut Value, patch: &Value) {
    if let (Some(target), Some(patch)) = (target.as_object_mut(), patch.as_object()) {
        for (key, value) in patch {
            if value.is_object() && target.get(key).is_some_and(Value::is_object) {
                merge(target.get_mut(key).unwrap(), value);
            } else {
                target.insert(key.clone(), value.clone());
            }
        }
    }
}
fn merged(raw: Option<String>, patch: &Value) -> Result<Value> {
    let mut value = match raw {
        Some(raw) => serde_json::from_str(&raw)?,
        None => json!({}),
    };
    value = clean(&value);
    merge(&mut value, &clean(patch));
    Ok(value)
}
fn enqueue(c: &Connection, kind: &str, channel: &str, root: &str) -> Result<()> {
    c.execute(
        "INSERT OR IGNORE INTO sync_jobs(kind,channel_id,thread_ts,updated_at) VALUES(?1,?2,?3,?4)",
        params![kind, channel, root, now_ms()],
    )?;
    Ok(())
}
fn conversation(c: &Connection, patch: &Value) -> Result<()> {
    let id = required(patch, "id")?;
    validate_channel(id)?;
    let protected = snapshot_patch(
        c,
        patch,
        &format!("event_read:{id}"),
        &["last_read", "latest", "has_unreads"],
    )?;
    let patch = &protected;
    let raw = c
        .query_row("SELECT raw FROM conversations WHERE id=?1", [id], |r| {
            r.get(0)
        })
        .optional()?;
    let value = merged(raw, patch)?;
    let kind = if value["is_im"].as_bool() == Some(true) {
        "im"
    } else if value["is_mpim"].as_bool() == Some(true) {
        "mpim"
    } else if value["is_private"].as_bool() == Some(true) {
        "private"
    } else {
        "channel"
    };
    c.execute("INSERT INTO conversations(id,name,kind,is_member,is_archived,raw) VALUES(?1,?2,?3,?4,?5,?6) ON CONFLICT(id) DO UPDATE SET name=excluded.name,kind=excluded.kind,is_member=excluded.is_member,is_archived=excluded.is_archived,raw=excluded.raw",params![id,string(&value,"name"),kind,value["is_member"].as_bool().unwrap_or(kind=="im" || kind=="mpim"),value["is_archived"].as_bool().unwrap_or(false),value.to_string()])?;
    enqueue(c, "history", id, "")?;
    channel_read(c, id, patch)?;
    Ok(())
}
fn user(c: &Connection, patch: &Value) -> Result<()> {
    let id = required(patch, "id")?;
    let raw = c
        .query_row("SELECT raw FROM users WHERE id=?1", [id], |r| r.get(0))
        .optional()?;
    let value = merged(raw, patch)?;
    c.execute(
        "INSERT INTO users(id,raw) VALUES(?1,?2) ON CONFLICT(id) DO UPDATE SET raw=excluded.raw",
        params![id, value.to_string()],
    )?;
    Ok(())
}
fn save_edit(c: &Connection, channel: &str, ts: &str, raw: &str) -> Result<()> {
    c.execute(
        "INSERT INTO message_edits(channel_id,ts,raw,captured_at) VALUES(?1,?2,?3,?4)",
        params![channel, ts, raw, now_ms()],
    )?;
    Ok(())
}
fn message(c: &Connection, channel: &str, patch: &Value) -> Result<()> {
    validate_channel(channel)?;
    let ts = required(patch, "ts")?;
    validate_timestamp(ts)?;
    if let Some(root) = patch.get("thread_ts").filter(|v| !v.is_null()) {
        validate_timestamp(
            root.as_str()
                .ok_or_else(|| ProjectionError("invalid thread_ts".into()))?,
        )?;
    }
    let protected = snapshot_patch(
        c,
        patch,
        &format!("event_reactions:{channel}:{ts}"),
        &["reactions"],
    )?;
    let patch = &protected;
    let old: Option<(String, bool)> = c
        .query_row(
            "SELECT raw,deleted FROM messages WHERE channel_id=?1 AND ts=?2",
            params![channel, ts],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?;
    // A historical page must never resurrect a tombstone or overwrite its snapshot.
    if old.as_ref().is_some_and(|(_, deleted)| *deleted) {
        return Ok(());
    }
    let previous = old
        .as_ref()
        .map(|(raw, _)| serde_json::from_str::<Value>(raw))
        .transpose()?;
    let root = patch["thread_ts"]
        .as_str()
        .or_else(|| previous.as_ref().and_then(|v| v["thread_ts"].as_str()))
        .unwrap_or(ts);
    let protected = snapshot_patch(
        c,
        patch,
        &format!("event_thread_read:{channel}:{root}"),
        &["last_read", "subscribed"],
    )?;
    let patch = &protected;
    let mut value = merged(old.as_ref().map(|(raw, _)| raw.clone()), patch)?;
    if let Some((raw, _)) = &old {
        let previous: Value = serde_json::from_str(raw)?;
        // Historical snapshots older than a known edit cannot replace current content.
        let prior_edit = string(&previous["edited"], "ts");
        let next_edit = string(&value["edited"], "ts");
        if !prior_edit.is_empty() && (patch.get("edited").is_none() || next_edit < prior_edit) {
            for field in ["text", "blocks", "attachments", "edited"] {
                if let Some(v) = previous.get(field) {
                    value[field] = v.clone();
                }
            }
        }
        if previous.get("text") != value.get("text")
            || previous.get("edited") != value.get("edited")
        {
            save_edit(c, channel, ts, raw)?;
        }
    }
    c.execute("INSERT INTO messages(channel_id,ts,thread_ts,user_id,text,raw) VALUES(?1,?2,?3,?4,?5,?6) ON CONFLICT(channel_id,ts) DO UPDATE SET thread_ts=excluded.thread_ts,user_id=excluded.user_id,text=excluded.text,raw=excluded.raw",params![channel,ts,value.get("thread_ts").and_then(Value::as_str),value.get("user").and_then(Value::as_str),string(&value,"text"),value.to_string()])?;
    if value["reply_count"].as_u64().unwrap_or(0) > 0
        || value.get("thread_ts").and_then(Value::as_str).is_some()
    {
        let root = value.get("thread_ts").and_then(Value::as_str).unwrap_or(ts);
        enqueue(c, "thread", channel, root)?;
        thread_read(c, channel, root, patch)?;
    }
    if let Some(reactions) = patch.get("reactions").and_then(Value::as_array) {
        let complete = reactions.iter().all(|r| {
            r["users"].as_array().is_some_and(|users| {
                r["count"]
                    .as_u64()
                    .is_none_or(|count| count == users.len() as u64)
            })
        });
        // Slack can omit some reaction users; an incomplete snapshot is additive.
        if complete {
            c.execute(
                "DELETE FROM reactions WHERE channel_id=?1 AND ts=?2",
                params![channel, ts],
            )?;
        }
        for reaction in reactions {
            if let Some(users) = reaction["users"].as_array() {
                for uid in users.iter().filter_map(Value::as_str) {
                    c.execute("INSERT OR IGNORE INTO reactions(channel_id,ts,name,user_id) VALUES(?1,?2,?3,?4)",params![channel,ts,string(reaction,"name"),uid])?;
                }
            }
        }
    }
    if let Some(files) = patch["files"].as_array() {
        for f in files {
            file(c, f)?;
        }
    }
    Ok(())
}
fn file(c: &Connection, patch: &Value) -> Result<()> {
    let id = required(patch, "id")?;
    let raw = c
        .query_row("SELECT raw FROM files WHERE id=?1", [id], |r| r.get(0))
        .optional()?;
    let value = merged(raw, patch)?;
    c.execute(
        "INSERT INTO files(id,raw) VALUES(?1,?2) ON CONFLICT(id) DO UPDATE SET raw=excluded.raw",
        params![id, value.to_string()],
    )?;
    Ok(())
}
fn channel_read(c: &Connection, channel: &str, patch: &Value) -> Result<()> {
    validate_channel(channel)?;
    let supplied_marker = patch.get("ts").is_some() || patch.get("last_read").is_some();
    let protected = snapshot_patch(
        c,
        patch,
        &format!("event_read:{channel}"),
        &["last_read", "latest", "has_unreads", "ts"],
    )?;
    let patch = &protected;
    if !["last_read", "latest", "has_unreads"]
        .iter()
        .any(|k| patch.get(k).is_some())
        && !string(patch, "type").ends_with("marked")
    {
        return Ok(());
    }
    if supplied_marker
        && string(patch, "type").ends_with("marked")
        && patch.get("ts").is_none()
        && patch.get("last_read").is_none()
    {
        return Ok(());
    }
    validate_read_fields(patch)?;
    let raw = c
        .query_row(
            "SELECT raw FROM channel_reads WHERE channel_id=?1",
            [channel],
            |r| r.get(0),
        )
        .optional()?;
    let mut state = json!({});
    for field in ["last_read", "latest", "has_unreads"] {
        if let Some(v) = patch.get(field) {
            state[field] = v.clone();
        }
    }
    if string(patch, "type").ends_with("marked") {
        if let Some(v) = patch.get("ts") {
            state["last_read"] = v.clone();
        }
    }
    let value = merged(raw, &state)?;
    let latest = value
        .get("latest")
        .and_then(|v| v.as_str().or_else(|| v["ts"].as_str()));
    c.execute("INSERT INTO channel_reads(channel_id,last_read,latest,has_unreads,raw) VALUES(?1,?2,?3,?4,?5) ON CONFLICT(channel_id) DO UPDATE SET last_read=excluded.last_read,latest=excluded.latest,has_unreads=excluded.has_unreads,raw=excluded.raw",params![channel,value["last_read"].as_str(),latest,value["has_unreads"].as_bool(),value.to_string()])?;
    Ok(())
}
fn thread_read(c: &Connection, channel: &str, root: &str, patch: &Value) -> Result<()> {
    validate_channel(channel)?;
    validate_timestamp(root)?;
    let protected = snapshot_patch(
        c,
        patch,
        &format!("event_thread_read:{channel}:{root}"),
        &["last_read", "subscribed"],
    )?;
    let patch = &protected;
    if patch.get("last_read").is_none() && patch.get("subscribed").is_none() {
        return Ok(());
    }
    validate_read_fields(patch)?;
    let raw = c
        .query_row(
            "SELECT raw FROM thread_reads WHERE channel_id=?1 AND thread_ts=?2",
            params![channel, root],
            |r| r.get(0),
        )
        .optional()?;
    let mut state = json!({});
    for field in ["last_read", "subscribed"] {
        if let Some(v) = patch.get(field) {
            state[field] = v.clone();
        }
    }
    let value = merged(raw, &state)?;
    c.execute("INSERT INTO thread_reads(channel_id,thread_ts,last_read,subscribed,raw) VALUES(?1,?2,?3,?4,?5) ON CONFLICT(channel_id,thread_ts) DO UPDATE SET last_read=excluded.last_read,subscribed=excluded.subscribed,raw=excluded.raw",params![channel,root,value["last_read"].as_str(),value["subscribed"].as_bool(),value.to_string()])?;
    Ok(())
}

fn validate_read_fields(patch: &Value) -> Result<()> {
    if let Some(value) = patch.get("last_read").filter(|v| !v.is_null()) {
        validate_timestamp(
            value
                .as_str()
                .ok_or_else(|| ProjectionError("invalid last_read".into()))?,
        )?;
    }
    if let Some(latest) = patch.get("latest").filter(|v| !v.is_null()) {
        let ts = latest
            .as_str()
            .or_else(|| latest["ts"].as_str())
            .ok_or_else(|| ProjectionError("invalid latest timestamp".into()))?;
        validate_timestamp(ts)?;
    }
    for key in ["has_unreads", "subscribed"] {
        if patch
            .get(key)
            .is_some_and(|v| !v.is_null() && !v.is_boolean())
        {
            return Err(ProjectionError(format!("invalid {key}")).into());
        }
    }
    if string(patch, "type").ends_with("marked") && patch.get("last_read").is_none() {
        validate_timestamp(required(patch, "ts")?)?;
    }
    Ok(())
}

const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT);
CREATE TABLE IF NOT EXISTS users(id TEXT PRIMARY KEY,raw TEXT);
CREATE TABLE IF NOT EXISTS conversations(id TEXT PRIMARY KEY,name TEXT,kind TEXT,is_member INTEGER,is_archived INTEGER,raw TEXT);
CREATE TABLE IF NOT EXISTS messages(channel_id TEXT,ts TEXT,thread_ts TEXT,user_id TEXT,text TEXT,raw TEXT,deleted INTEGER DEFAULT 0,PRIMARY KEY(channel_id,ts));
CREATE TABLE IF NOT EXISTS message_edits(id INTEGER PRIMARY KEY,channel_id TEXT,ts TEXT,raw TEXT,captured_at INTEGER);
CREATE TABLE IF NOT EXISTS events(id INTEGER PRIMARY KEY,received_at INTEGER,event_type TEXT,raw TEXT);
CREATE TABLE IF NOT EXISTS reactions(channel_id TEXT,ts TEXT,name TEXT,user_id TEXT,PRIMARY KEY(channel_id,ts,name,user_id));
CREATE TABLE IF NOT EXISTS files(id TEXT PRIMARY KEY,raw TEXT,deleted INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS channel_reads(channel_id TEXT PRIMARY KEY,last_read TEXT,latest TEXT,has_unreads INTEGER,raw TEXT);
CREATE TABLE IF NOT EXISTS thread_reads(channel_id TEXT,thread_ts TEXT,last_read TEXT,subscribed INTEGER,raw TEXT,PRIMARY KEY(channel_id,thread_ts));
CREATE TABLE IF NOT EXISTS sync_jobs(kind TEXT,channel_id TEXT,thread_ts TEXT NOT NULL DEFAULT '',cursor TEXT,oldest_ts TEXT,latest_ts TEXT,newest_ts TEXT,complete INTEGER DEFAULT 0,error TEXT,retry_at INTEGER DEFAULT 0,updated_at INTEGER DEFAULT 0,PRIMARY KEY(kind,channel_id,thread_ts));
CREATE INDEX IF NOT EXISTS messages_thread ON messages(channel_id,thread_ts,ts);
CREATE INDEX IF NOT EXISTS messages_time ON messages(ts,channel_id);
CREATE INDEX IF NOT EXISTS messages_sender ON messages(user_id,ts,channel_id);
CREATE INDEX IF NOT EXISTS message_edits_message ON message_edits(channel_id,ts);
CREATE INDEX IF NOT EXISTS sync_jobs_channel ON sync_jobs(channel_id,kind,thread_ts);
CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(text,channel_id UNINDEXED,ts UNINDEXED);
CREATE TRIGGER IF NOT EXISTS messages_fts_insert AFTER INSERT ON messages WHEN new.deleted=0 BEGIN
 INSERT INTO messages_fts(rowid,text,channel_id,ts) VALUES(new.rowid,new.text,new.channel_id,new.ts); END;
CREATE TRIGGER IF NOT EXISTS messages_fts_delete AFTER DELETE ON messages BEGIN
 DELETE FROM messages_fts WHERE rowid=old.rowid; END;
CREATE TRIGGER IF NOT EXISTS messages_fts_update AFTER UPDATE ON messages BEGIN
 DELETE FROM messages_fts WHERE rowid=old.rowid;
 INSERT INTO messages_fts(rowid,text,channel_id,ts) SELECT new.rowid,new.text,new.channel_id,new.ts WHERE new.deleted=0; END;
"#;
