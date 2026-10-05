use crate::{
    session::cookie_header,
    slack::{self, ApiError, SlackClient},
    store::{now_ms, ProjectionError, Store},
};
use anyhow::Result;
use futures_util::{SinkExt, StreamExt};
use rusqlite::{params, OptionalExtension};
use serde_json::{json, Value};
use std::{sync::Arc, time::Duration};
use tokio::{
    sync::Notify,
    time::{self, Instant},
};
use tokio_tungstenite::{
    connect_async_with_config,
    tungstenite::{client::IntoClientRequest, protocol::WebSocketConfig, Message},
};

fn timestamp() -> String {
    let now = chrono::Utc::now();
    format!(
        "{:010}.{:06}",
        now.timestamp(),
        now.timestamp_subsec_micros()
    )
}
fn valid_ts(value: &str) -> bool {
    value.len() == 17
        && value.as_bytes()[10] == b'.'
        && value
            .bytes()
            .enumerate()
            .all(|(i, b)| i == 10 || b.is_ascii_digit())
}
fn text<'a>(value: &'a Value, field: &str) -> &'a str {
    value[field].as_str().unwrap_or("")
}
fn next_cursor(value: &Value, required: bool) -> Result<String> {
    let Some(metadata) = value.get("response_metadata") else {
        return if required {
            Err(slack::error("invalid_page"))
        } else {
            Ok(String::new())
        };
    };
    let metadata = metadata
        .as_object()
        .ok_or_else(|| slack::error("invalid_page"))?;
    match metadata.get("next_cursor") {
        Some(Value::String(s)) => Ok(s.trim().to_owned()),
        None if !required => Ok(String::new()),
        _ => Err(slack::error("invalid_page")),
    }
}
fn has_more(value: &Value) -> Result<bool> {
    value
        .get("has_more")
        .and_then(Value::as_bool)
        .ok_or_else(|| slack::error("invalid_page"))
}
fn recoverable(e: &anyhow::Error) -> bool {
    e.downcast_ref::<ApiError>().is_some() || e.downcast_ref::<ProjectionError>().is_some()
}
fn failure_code(e: &anyhow::Error) -> &'static str {
    if e.downcast_ref::<ProjectionError>().is_some() {
        "invalid_entity"
    } else {
        slack::code(e)
    }
}
fn snapshot_id(store: &Store) -> Result<i64> {
    store
        .with_conn(|c| Ok(c.query_row("SELECT coalesce(max(id),0) FROM events", [], |r| r.get(0))?))
}
fn snapshot_entity(value: &Value, event_id: i64) -> Result<Value> {
    let mut value = value.clone();
    let object = value
        .as_object_mut()
        .ok_or_else(|| slack::error("invalid_entity"))?;
    object.insert("__mirror_snapshot_event_id".into(), event_id.into());
    Ok(value)
}
fn retry_delay(e: &anyhow::Error, previous_ms: i64) -> i64 {
    let rate = e
        .downcast_ref::<ApiError>()
        .map(|e| e.retry_after.as_millis().min(i64::MAX as u128) as i64)
        .unwrap_or(0);
    rate.max((previous_ms.max(1000) * 2).min(300_000))
}
fn meta_tx(c: &rusqlite::Connection, key: &str, value: &str) -> Result<()> {
    c.execute("INSERT INTO meta(key,value) VALUES(?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value", params![key,value])?;
    Ok(())
}
fn generation_key(channel: &str, root: &str) -> String {
    format!("thread_dirty:{channel}:{root}")
}
fn scan_key(channel: &str, root: &str) -> String {
    format!("thread_scan:{channel}:{root}")
}
fn generation(c: &rusqlite::Connection, key: &str) -> Result<String> {
    Ok(
        c.query_row("SELECT value FROM meta WHERE key=?1", [key], |r| r.get(0))
            .optional()?
            .unwrap_or_else(|| "0".into()),
    )
}

pub async fn run(store: Store, slack: SlackClient) -> Result<()> {
    let result: Result<()> = async {
        slack.bind(store.clone()).await?;
        store.set_meta("sync_state", "running")?;
        store.set_meta("historical_refresh_interval_seconds", "86400")?;
        if store.meta("backfill_started_at")?.is_none() {
            store.set_meta("backfill_started_at", &now_ms().to_string())?;
        }
        let reconcile = Arc::new(Notify::new());
        tokio::try_join!(
            realtime(store.clone(), slack.clone(), reconcile.clone()),
            scheduler(store.clone(), slack, reconcile)
        )?;
        Ok(())
    }
    .await;
    if let Err(ref e) = result {
        store.set_meta("engine_error", slack::code(e))?;
        store.set_meta("sync_state", "error")?;
        if slack::auth_error(e) {
            store.set_meta("auth_error", slack::code(e))?;
            store.set_meta("auth_state", "error")?;
        }
    }
    result
}

async fn realtime(store: Store, client: SlackClient, reconcile: Arc<Notify>) -> Result<()> {
    let mut delay = 1u64;
    loop {
        store.set_meta("rtm_state", "connecting")?;
        let started = Instant::now();
        let result = socket(&store, &client, &reconcile).await;
        store.set_meta("rtm_state", "disconnected")?;
        store.set_meta("last_disconnected_at", &now_ms().to_string())?;
        reconcile.notify_one();
        match result {
            Err(e) if slack::auth_error(&e) || e.downcast_ref::<ApiError>().is_none() => {
                return Err(e)
            }
            Err(e) => {
                store.set_meta("rtm_state", slack::code(&e))?;
                if slack::code(&e) == "session_changed" {
                    delay = 1;
                    continue;
                }
                let rate = e.downcast_ref::<ApiError>().unwrap().retry_after;
                time::sleep(rate.max(Duration::from_secs(delay))).await;
            }
            Ok(()) => time::sleep(Duration::from_secs(delay)).await,
        }
        delay = if started.elapsed() > Duration::from_secs(60) {
            1
        } else {
            (delay * 2).min(60)
        };
    }
}

async fn socket(store: &Store, client: &SlackClient, reconcile: &Notify) -> Result<()> {
    let (connection, digest) = client
        .call_checked(
            "rtm.connect",
            &[("batch_presence_aware".into(), "1".into())],
        )
        .await?;
    let session = client.checked_session().await?;
    client.unchanged(&digest)?;
    if slack::fingerprint(&session) != digest {
        return Err(slack::error("session_changed"));
    }
    // Only Slack's TLS endpoints may receive the session cookie. Never retain the URL.
    let url = url::Url::parse(text(&connection, "url"))
        .map_err(|_| slack::error("invalid_rtm_endpoint"))?;
    if url.scheme() != "wss"
        || !url.username().is_empty()
        || url.password().is_some()
        || url.fragment().is_some()
        || url.port().is_some_and(|p| p != 443)
        || !url
            .host_str()
            .is_some_and(|h| h.ends_with(".slack.com") || h.ends_with(".slack-msgs.com"))
    {
        return Err(slack::error("invalid_rtm_endpoint"));
    }
    let mut request = url
        .as_str()
        .into_client_request()
        .map_err(|_| slack::error("invalid_rtm_endpoint"))?;
    request.headers_mut().insert(
        "Cookie",
        cookie_header(&session.cookie)
            .parse()
            .map_err(|_| slack::error("session_unavailable"))?,
    );
    request
        .headers_mut()
        .insert("Origin", "https://app.slack.com".parse().unwrap());
    let mut config = WebSocketConfig::default();
    config.max_message_size = Some(8 * 1024 * 1024);
    config.max_frame_size = Some(8 * 1024 * 1024);
    let (mut ws, _) = time::timeout(
        Duration::from_secs(20),
        connect_async_with_config(request, Some(config), true),
    )
    .await
    .map_err(|_| slack::error("rtm_connect_timeout"))?
    .map_err(|_| slack::error("rtm_connect_failed"))?;
    client.unchanged(&digest)?;
    store.set_meta("rtm_state", "connected")?;
    store.set_meta("last_connected_at", &now_ms().to_string())?;
    reconcile.notify_one();
    let mut tick = time::interval(Duration::from_secs(1));
    tick.set_missed_tick_behavior(time::MissedTickBehavior::Skip);
    let mut last_frame = Instant::now();
    let mut last_ping = Instant::now();
    let mut id = 0u64;
    loop {
        tokio::select! {
            _ = tick.tick() => {
                client.unchanged(&digest)?;
                if last_frame.elapsed() >= Duration::from_secs(45) { return Err(slack::error("rtm_stale")); }
                if last_ping.elapsed() >= Duration::from_secs(15) {
                    id += 1;
                    let ping = Message::Text(json!({"id":id,"type":"ping"}).to_string().into());
                    time::timeout(Duration::from_secs(10), ws.send(ping)).await
                        .map_err(|_| slack::error("rtm_write_timeout"))?.map_err(|_| slack::error("rtm_write_failed"))?;
                    last_ping = Instant::now();
                }
            }
            frame = ws.next() => {
                let frame = frame.ok_or_else(|| slack::error("rtm_closed"))?.map_err(|_| slack::error("rtm_read_failed"))?;
                client.unchanged(&digest)?;
                last_frame = Instant::now();
                store.set_meta("last_event_at", &now_ms().to_string())?;
                let payload = match frame {
                    Message::Text(s) => Some(s.as_bytes().to_vec()),
                    Message::Binary(b) => Some(b.to_vec()),
                    Message::Close(_) => return Err(slack::error("rtm_closed")),
                    Message::Ping(_) => {
                        time::timeout(Duration::from_secs(10), ws.flush()).await
                            .map_err(|_| slack::error("rtm_write_timeout"))?.map_err(|_| slack::error("rtm_write_failed"))?;
                        None
                    }
                    _ => None,
                };
                if let Some(payload) = payload {
                    if let Ok(mut event) = serde_json::from_slice::<Value>(&payload) {
                        if !event.is_object() { continue; }
                        let goodbye = text(&event, "type") == "goodbye";
                        if text(&event, "type") == "reconnect_url" { event.as_object_mut().unwrap().remove("url"); }
                        store.apply_event(&event)?;
                        wake_thread(store, &event)?;
                        if goodbye { return Err(slack::error("rtm_goodbye")); }
                    }
                }
            }
        }
    }
}

fn wake_thread(store: &Store, event: &Value) -> Result<()> {
    if text(event, "type") != "message" {
        return Ok(());
    }
    let channel = text(event, "channel");
    let message = event.get("message").unwrap_or(event);
    let root = message["thread_ts"].as_str().or_else(|| {
        (message["reply_count"].as_u64().unwrap_or(0) > 0).then(|| text(message, "ts"))
    });
    if let Some(root) = root.filter(|root| valid_ts(root)) {
        store.with_conn(|c| {
            let tx = c.transaction()?;
            let key = generation_key(channel, root);
            let previous = generation(&tx, &key)?.parse::<u64>().unwrap_or(0);
            meta_tx(&tx, &key, &previous.saturating_add(1).to_string())?;
            // An in-flight crawl keeps its cursor; completion compares its generation.
            tx.execute("UPDATE sync_jobs SET complete=0,oldest_ts=latest_ts,latest_ts=NULL,newest_ts=NULL,cursor=NULL,retry_at=0,error=NULL,updated_at=?3 WHERE kind='thread' AND channel_id=?1 AND thread_ts=?2 AND complete=1", params![channel,root,now_ms()])?;
            tx.commit()?;
            Ok(())
        })?;
    }
    Ok(())
}

struct Catalog {
    method: &'static str,
    cursor: String,
    done: bool,
    retry_at: Instant,
    delay_ms: i64,
    error: Option<&'static str>,
    unavailable: bool,
    attempted_at: i64,
    pages: u64,
    waiting: bool,
}
impl Catalog {
    fn new(method: &'static str) -> Self {
        Self {
            method,
            cursor: String::new(),
            done: false,
            retry_at: Instant::now(),
            delay_ms: 0,
            error: None,
            unavailable: false,
            attempted_at: 0,
            pages: 0,
            waiting: false,
        }
    }
}

fn catalog_status(store: &Store, task: &Catalog) -> Result<()> {
    let retry_ms = task
        .retry_at
        .saturating_duration_since(Instant::now())
        .as_millis()
        .min(i64::MAX as u128) as i64;
    store.set_meta(&format!("catalog:{}", task.method), &json!({
        "complete":task.done,"error":task.error,"unavailable":task.unavailable,
        "pages":task.pages,"has_cursor":!task.cursor.is_empty(),"attempted_at":task.attempted_at,
        "waiting":task.waiting,
        "retry_at":if task.done || task.unavailable {0} else {now_ms().saturating_add(retry_ms)}
    }).to_string())
}

fn engine_health(store: &Store, catalog: &[Catalog]) -> Result<()> {
    if let Some(error) = catalog.iter().find_map(|task| task.error) {
        return store.set_meta("engine_error", error);
    }
    let failed_job = store.with_conn(|c| {
        Ok(c.query_row(
            "SELECT EXISTS(SELECT 1 FROM sync_jobs WHERE error IS NOT NULL AND error NOT IN ('ratelimited','request_deferred'))",
            [],
            |r| r.get::<_, bool>(0),
        )?)
    })?;
    if failed_job {
        store.set_meta("engine_error", "pending_job_error")?;
    } else if catalog.iter().all(|task| task.attempted_at > 0) {
        store.set_meta("engine_error", "")?;
    }
    Ok(())
}

async fn scheduler(store: Store, client: SlackClient, notify: Arc<Notify>) -> Result<()> {
    let methods = [
        "users.conversations",
        "conversations.list",
        "users.list",
        "client.userBoot",
        "client.counts",
        "subscriptions.thread.getView",
    ];
    let mut catalog: Vec<_> = methods.into_iter().map(Catalog::new).collect();
    let mut last_reconcile = Instant::now();
    let mut reported = false;
    let mut history_turn = 0usize;
    prepare_reconcile(&store)?;
    loop {
        client.checked_session().await?;
        let requested = tokio::select! {
            _ = notify.notified() => true,
            _ = time::sleep(Duration::from_millis(500)) => false,
        };
        if requested || last_reconcile.elapsed() >= Duration::from_secs(300) {
            prepare_reconcile(&store)?;
            // Do not discard pagination or a rate-limit deadline on a reconnect.
            for task in &mut catalog {
                if task.done || task.unavailable {
                    task.done = false;
                    task.unavailable = false;
                    task.cursor.clear();
                    task.pages = 0;
                    task.waiting = false;
                }
            }
            last_reconcile = Instant::now();
            reported = false;
        }
        for task in &mut catalog {
            if task.done || task.unavailable || Instant::now() < task.retry_at {
                continue;
            }
            let wait = client.ready_after(task.method).await;
            if !wait.is_zero() {
                task.retry_at = Instant::now() + wait;
                task.waiting = true;
                catalog_status(&store, task)?;
                continue;
            }
            task.attempted_at = now_ms();
            match catalog_page(&store, &client, task).await {
                Ok(()) => {
                    task.delay_ms = 0;
                    task.error = None;
                    task.pages += 1;
                    task.waiting = false;
                }
                Err(e) if slack::auth_error(&e) || !recoverable(&e) => return Err(e),
                Err(e) if slack::deferred(&e) => {
                    task.error = None;
                    task.waiting = true;
                    let wait = e.downcast_ref::<ApiError>().unwrap().retry_after;
                    task.retry_at = Instant::now() + wait;
                }
                Err(e) => {
                    task.waiting = false;
                    task.error = Some(failure_code(&e));
                    task.unavailable = matches!(
                        failure_code(&e),
                        "missing_scope"
                            | "access_denied"
                            | "unknown_method"
                            | "unsupported_session"
                    );
                    store.set_meta("engine_error", failure_code(&e))?;
                    if slack::code(&e) == "invalid_cursor" {
                        task.cursor.clear();
                    }
                    task.delay_ms = retry_delay(&e, task.delay_ms);
                    task.retry_at = Instant::now() + Duration::from_millis(task.delay_ms as u64);
                }
            }
            catalog_status(&store, task)?;
            time::sleep(Duration::from_millis(100)).await;
        }
        // These queues share one API quota. Rotate so gap catch-up cannot starve backfill.
        let history_kinds = ["gap", "history", "gap", "history", "refresh"];
        for _ in 0..8 {
            if !client.ready_after("conversations.history").await.is_zero() {
                break;
            }
            let mut attempted = false;
            for offset in 0..history_kinds.len() {
                let index = (history_turn + offset) % history_kinds.len();
                if crawl(&store, &client, history_kinds[index], 1).await? > 0 {
                    history_turn = (index + 1) % history_kinds.len();
                    attempted = true;
                    break;
                }
            }
            if !attempted {
                break;
            }
        }
        crawl(&store, &client, "thread", 16).await?;
        engine_health(&store, &catalog)?;
        store.set_meta(
            "catalog_reconcile_complete",
            if catalog.iter().all(|task| task.done) {
                "true"
            } else {
                "false"
            },
        )?;
        if !reported && catalog.iter().all(|t| t.done || t.error.is_some()) {
            store.set_meta("last_reconcile_at", &now_ms().to_string())?;
            store.set_meta("last_sync_at", &now_ms().to_string())?;
            reported = true;
        }
    }
}

fn prepare_reconcile(store: &Store) -> Result<()> {
    store.with_conn(|c| {
        let tx = c.transaction()?;
        let now = now_ms();
        // The history snapshot boundary, never max(message.ts), is the first gap floor.
        tx.execute("INSERT OR IGNORE INTO sync_jobs(kind,channel_id,thread_ts,oldest_ts,newest_ts,complete,updated_at) SELECT 'gap',channel_id,'',newest_ts,newest_ts,1,?1 FROM sync_jobs WHERE kind='history' AND newest_ts IS NOT NULL", [now])?;
        let mut statement = tx.prepare("SELECT channel_id,newest_ts FROM sync_jobs WHERE kind='gap' AND complete=1")?;
        let gaps = statement.query_map([], |r| Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?)))?.collect::<rusqlite::Result<Vec<_>>>()?;
        drop(statement);
        for (channel, lower) in gaps {
            meta_tx(&tx, &format!("gap_lower:{channel}"), &lower)?;
            let upper = timestamp();
            tx.execute("UPDATE sync_jobs SET complete=0,cursor=NULL,oldest_ts=NULL,latest_ts=?2,newest_ts=?2,error=NULL,retry_at=0,updated_at=?3 WHERE kind='gap' AND channel_id=?1", params![channel,upper,now])?;
        }
        let mut statement = tx.prepare("SELECT channel_id FROM sync_jobs WHERE kind='history' AND complete=1")?;
        let channels = statement.query_map([], |r| r.get::<_,String>(0))?.collect::<rusqlite::Result<Vec<_>>>()?;
        drop(statement);
        for channel in channels {
            let last = generation(&tx, &format!("history_full_refresh:{channel}"))?.parse::<i64>().unwrap_or(0);
            if now.saturating_sub(last) >= 86_400_000 {
                // A pending refresh retains its snapshot bounds and cursor across reconciliation.
                tx.execute("INSERT INTO sync_jobs(kind,channel_id,thread_ts,updated_at) VALUES('refresh',?1,'',?2) ON CONFLICT(kind,channel_id,thread_ts) DO UPDATE SET cursor=NULL,oldest_ts=NULL,latest_ts=NULL,newest_ts=NULL,complete=0,error=NULL,retry_at=0,updated_at=excluded.updated_at WHERE sync_jobs.complete=1", params![channel,now])?;
            }
        }
        let mut statement = tx.prepare("SELECT channel_id,thread_ts,latest_ts FROM sync_jobs WHERE kind='thread' AND complete=1")?;
        let threads = statement.query_map([], |r| Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?,r.get::<_,Option<String>>(2)?)))?.collect::<rusqlite::Result<Vec<_>>>()?;
        drop(statement);
        for (channel, root, latest) in threads {
            let last = generation(&tx, &format!("thread_full_refresh:{channel}:{root}"))?.parse::<i64>().unwrap_or(0);
            let full = now.saturating_sub(last) >= 86_400_000;
            tx.execute("UPDATE sync_jobs SET complete=0,cursor=NULL,oldest_ts=?3,latest_ts=NULL,newest_ts=NULL,error=NULL,retry_at=0,updated_at=?4 WHERE kind='thread' AND channel_id=?1 AND thread_ts=?2", params![channel,root,if full {None} else {latest},now])?;
        }
        tx.commit()?;
        Ok(())
    })
}

async fn catalog_page(store: &Store, client: &SlackClient, task: &mut Catalog) -> Result<()> {
    let mut fields = vec![("limit".into(), "200".into())];
    if !task.cursor.is_empty() {
        fields.push((
            if task.method == "subscriptions.thread.getView" {
                "current_ts"
            } else {
                "cursor"
            }
            .into(),
            task.cursor.clone(),
        ));
    }
    match task.method {
        "users.conversations" => fields.extend([
            (
                "types".into(),
                "public_channel,private_channel,mpim,im".into(),
            ),
            ("exclude_archived".into(), "false".into()),
        ]),
        "conversations.list" => fields.extend([
            ("types".into(), "public_channel".into()),
            ("exclude_archived".into(), "false".into()),
        ]),
        "client.counts" => fields.extend([
            ("thread_counts_by_channel".into(), "true".into()),
            ("org_wide_aware".into(), "true".into()),
            ("include_file_channels".into(), "true".into()),
        ]),
        "client.userBoot" => fields.extend([
            ("min_channel_updated".into(), "0".into()),
            ("version_ts".into(), "0".into()),
            ("build_version_ts".into(), "0".into()),
        ]),
        "subscriptions.thread.getView" => fields.push(("priority_mode".into(), "all".into())),
        _ => {}
    }
    let event_id = snapshot_id(store)?;
    let (value, digest) = client.call_checked(task.method, &fields).await?;
    let paginated = matches!(
        task.method,
        "users.list" | "users.conversations" | "conversations.list"
    );
    let cursor = if paginated {
        next_cursor(&value, true)?
    } else {
        if !next_cursor(&value, false)?.is_empty() {
            return Err(slack::error("invalid_page"));
        }
        if task.method != "subscriptions.thread.getView"
            && value.get("has_more").is_some()
            && has_more(&value)?
        {
            return Err(slack::error("invalid_page"));
        }
        String::new()
    };
    if paginated {
        if let Some(more) = value.get("has_more") {
            let more = more.as_bool().ok_or_else(|| slack::error("invalid_page"))?;
            if more != !cursor.is_empty() {
                return Err(slack::error("invalid_page"));
            }
        }
    }
    if !cursor.is_empty() && cursor == task.cursor {
        return Err(slack::error("pagination_stalled"));
    }
    client.unchanged(&digest)?;
    match task.method {
        "users.list" => {
            for user in value["members"]
                .as_array()
                .ok_or_else(|| slack::error("invalid_page"))?
            {
                store.upsert_user(&snapshot_entity(user, event_id)?)?;
            }
        }
        "subscriptions.thread.getView" => {
            let threads = value["threads"]
                .as_array()
                .ok_or_else(|| slack::error("invalid_page"))?;
            let more = has_more(&value)?;
            let mut last_position: Option<String> = None;
            for thread in threads {
                if !thread.is_object() {
                    return Err(slack::error("invalid_entity"));
                }
                let mut root = snapshot_entity(&thread["root_msg"], event_id)?;
                let channel = text(&root, "channel").to_owned();
                if channel.is_empty() {
                    return Err(slack::error("invalid_page"));
                }
                if root.get("subscribed").is_none() {
                    root["subscribed"] = true.into();
                }
                store.upsert_conversation(&snapshot_entity(&json!({"id":channel}), event_id)?)?;
                store.upsert_message(&channel, &root)?;
                for key in ["unread_replies", "latest_replies"] {
                    if let Some(values) = thread.get(key) {
                        let replies = values
                            .as_array()
                            .ok_or_else(|| slack::error("invalid_page"))?;
                        for reply in replies {
                            store.upsert_message(&channel, &snapshot_entity(reply, event_id)?)?;
                        }
                    }
                }
                let ts = root["latest_reply"]
                    .as_str()
                    .unwrap_or_else(|| text(&root, "ts"));
                if !valid_ts(ts) {
                    return Err(slack::error("invalid_page"));
                }
                if last_position
                    .as_deref()
                    .is_some_and(|previous| ts > previous)
                {
                    return Err(slack::error("invalid_page"));
                }
                last_position = Some(ts.to_owned());
            }
            if more {
                // max_ts in the response is a snapshot watermark, not the next-page cursor.
                let cursor = last_position.ok_or_else(|| slack::error("pagination_stalled"))?;
                if !task.cursor.is_empty() && cursor >= task.cursor {
                    return Err(slack::error("pagination_stalled"));
                }
                task.cursor = cursor;
            } else {
                task.done = true;
            }
            return Ok(());
        }
        _ => {
            let keys: &[&str] = if task.method == "client.counts" {
                &["channels", "ims", "mpims"]
            } else if task.method == "client.userBoot" {
                &["channels", "ims", "mpims", "groups"]
            } else {
                &["channels"]
            };
            for key in keys {
                if let Some(values) = value.get(*key) {
                    let items = values
                        .as_array()
                        .ok_or_else(|| slack::error("invalid_page"))?;
                    for item in items {
                        let mut item = snapshot_entity(item, event_id)?;
                        if matches!(task.method, "users.conversations" | "client.userBoot")
                            && item.get("is_member").is_none()
                        {
                            item["is_member"] = true.into();
                        }
                        if *key == "ims" {
                            item["is_im"] = true.into();
                        }
                        if *key == "mpims" {
                            item["is_mpim"] = true.into();
                        }
                        if *key == "groups" {
                            item["is_private"] = true.into();
                        }
                        store.upsert_conversation(&item)?;
                    }
                } else if matches!(
                    task.method,
                    "users.conversations" | "conversations.list" | "client.counts"
                ) {
                    return Err(slack::error("invalid_page"));
                }
            }
            if task.method == "client.userBoot" {
                if let Some(values) = value.get("is_open") {
                    let ids = values
                        .as_array()
                        .ok_or_else(|| slack::error("invalid_page"))?;
                    for id in ids {
                        let id = id
                            .as_str()
                            .filter(|id| !id.is_empty())
                            .ok_or_else(|| slack::error("invalid_entity"))?;
                        store
                            .upsert_conversation(&snapshot_entity(&json!({"id":id}), event_id)?)?;
                    }
                }
            }
        }
    }
    task.done = cursor.is_empty();
    task.cursor = cursor;
    Ok(())
}

struct Job {
    kind: String,
    channel: String,
    root: String,
    cursor: String,
    oldest: Option<String>,
    latest: Option<String>,
    newest: Option<String>,
    retry_at: i64,
    updated_at: i64,
}

fn take_job(store: &Store, kind: &str) -> Result<Option<Job>> {
    store.with_conn(|c| {
        let mut stmt = c.prepare("SELECT kind,channel_id,thread_ts,coalesce(cursor,''),oldest_ts,latest_ts,newest_ts,retry_at,updated_at FROM sync_jobs WHERE complete=0 AND retry_at<=?1 AND kind=?2 ORDER BY updated_at,channel_id,thread_ts LIMIT 1")?;
        Ok(stmt.query_row(params![now_ms(),kind], |r| Ok(Job {kind:r.get(0)?,channel:r.get(1)?,root:r.get(2)?,cursor:r.get(3)?,oldest:r.get(4)?,latest:r.get(5)?,newest:r.get(6)?,retry_at:r.get(7)?,updated_at:r.get(8)?})).optional()?)
    })
}

async fn crawl(store: &Store, client: &SlackClient, kind: &str, budget: usize) -> Result<usize> {
    let method = if kind == "thread" {
        "conversations.replies"
    } else {
        "conversations.history"
    };
    let mut attempted = 0;
    for _ in 0..budget {
        if !client.ready_after(method).await.is_zero() {
            break;
        }
        let Some(mut job) = take_job(store, kind)? else {
            break;
        };
        initialize_job(store, &mut job)?;
        attempted += 1;
        match job_page(store, client, &job).await {
            Ok(()) => {}
            Err(e) if slack::auth_error(&e) || !recoverable(&e) => return Err(e),
            Err(e) if slack::deferred(&e) => {
                let wait = e
                    .downcast_ref::<ApiError>()
                    .unwrap()
                    .retry_after
                    .as_millis()
                    .min(i64::MAX as u128) as i64;
                store.with_conn(|c| {
                    c.execute("UPDATE sync_jobs SET error=CASE WHEN error IN ('ratelimited','request_deferred') THEN NULL ELSE error END,retry_at=?4,updated_at=?5 WHERE kind=?1 AND channel_id=?2 AND thread_ts=?3", params![job.kind,job.channel,job.root,now_ms().saturating_add(wait),now_ms()])?;
                    Ok(())
                })?;
                break;
            }
            Err(e) => {
                store.set_meta("engine_error", failure_code(&e))?;
                let delay = retry_delay(&e, job.retry_at.saturating_sub(job.updated_at));
                store.with_conn(|c| {
                    let tx = c.transaction()?;
                    if slack::code(&e) == "invalid_cursor" {
                        if job.kind == "thread" {
                            tx.execute("UPDATE sync_jobs SET cursor=NULL,oldest_ts=coalesce(newest_ts,oldest_ts) WHERE kind=?1 AND channel_id=?2 AND thread_ts=?3", params![job.kind,job.channel,job.root])?;
                        } else {
                            tx.execute("UPDATE sync_jobs SET cursor=NULL,latest_ts=coalesce(oldest_ts,latest_ts) WHERE kind=?1 AND channel_id=?2 AND thread_ts=?3", params![job.kind,job.channel,job.root])?;
                        }
                    }
                    tx.execute("UPDATE sync_jobs SET error=?4,retry_at=?5,updated_at=?6 WHERE kind=?1 AND channel_id=?2 AND thread_ts=?3", params![job.kind,job.channel,job.root,failure_code(&e),now_ms().saturating_add(delay),now_ms()])?;
                    tx.commit()?;
                    Ok(())
                })?;
            }
        }
        time::sleep(Duration::from_millis(150)).await;
    }
    Ok(attempted)
}

fn initialize_job(store: &Store, job: &mut Job) -> Result<()> {
    if job.latest.is_some() {
        return Ok(());
    }
    let upper = timestamp();
    store.with_conn(|c| {
        let tx = c.transaction()?;
        if job.kind == "thread" {
            meta_tx(&tx, &scan_key(&job.channel, &job.root), &generation(&tx, &generation_key(&job.channel, &job.root))?)?;
            meta_tx(&tx, &format!("thread_full_scan:{}:{}", job.channel, job.root), if job.oldest.is_none() { "true" } else { "false" })?;
            tx.execute("UPDATE sync_jobs SET latest_ts=?4 WHERE kind=?1 AND channel_id=?2 AND thread_ts=?3", params![job.kind,job.channel,job.root,upper])?;
        } else {
            tx.execute("UPDATE sync_jobs SET latest_ts=?4,newest_ts=?4 WHERE kind=?1 AND channel_id=?2 AND thread_ts=?3", params![job.kind,job.channel,job.root,upper])?;
            job.newest = Some(upper.clone());
            if job.kind == "history" {
                tx.execute("INSERT OR IGNORE INTO sync_jobs(kind,channel_id,thread_ts,newest_ts,complete,updated_at) VALUES('gap',?1,'',?2,1,?3)", params![job.channel,upper,now_ms()])?;
            }
        }
        tx.commit()?;
        Ok(())
    })?;
    job.latest = Some(upper);
    Ok(())
}

async fn job_page(store: &Store, client: &SlackClient, job: &Job) -> Result<()> {
    let thread = job.kind == "thread";
    let lower = if job.kind == "gap" {
        store.meta(&format!("gap_lower:{}", job.channel))?
    } else if thread {
        job.oldest.clone()
    } else {
        None
    };
    let mut fields = vec![
        ("channel".into(), job.channel.clone()),
        ("limit".into(), "200".into()),
        ("inclusive".into(), "true".into()),
    ];
    if thread {
        fields.push(("ts".into(), job.root.clone()));
    }
    if let Some(lower) = &lower {
        fields.push(("oldest".into(), lower.clone()));
    }
    if let Some(latest) = &job.latest {
        fields.push(("latest".into(), latest.clone()));
    }
    if !job.cursor.is_empty() {
        fields.push(("cursor".into(), job.cursor.clone()));
    }
    let event_id = snapshot_id(store)?;
    let (value, digest) = client
        .call_checked(
            if thread {
                "conversations.replies"
            } else {
                "conversations.history"
            },
            &fields,
        )
        .await?;
    let messages = value["messages"]
        .as_array()
        .ok_or_else(|| slack::error("invalid_page"))?;
    let cursor = next_cursor(&value, false)?;
    let has_more = has_more(&value)?;
    if (!cursor.is_empty() && cursor == job.cursor) || (!has_more && !cursor.is_empty()) {
        return Err(slack::error("pagination_stalled"));
    }
    let mut minimum: Option<String> = None;
    let mut maximum: Option<String> = None;
    for message in messages {
        if !message.is_object() {
            return Err(slack::error("invalid_entity"));
        }
        let ts = text(message, "ts");
        if !valid_ts(ts) {
            return Err(slack::error("invalid_page"));
        }
        // Replies may include their root even when an oldest filter is supplied.
        if thread && ts == job.root {
            continue;
        }
        if lower.as_deref().is_some_and(|floor| ts < floor)
            || job.latest.as_deref().is_some_and(|ceiling| ts > ceiling)
        {
            return Err(slack::error("invalid_page"));
        }
        if lower.as_deref() == Some(ts) {
            continue;
        }
        minimum = Some(minimum.map_or_else(|| ts.into(), |old| old.min(ts.into())));
        maximum = Some(maximum.map_or_else(|| ts.into(), |old| old.max(ts.into())));
    }
    if has_more && cursor.is_empty() {
        let advancing = if thread {
            maximum
                .as_deref()
                .is_some_and(|ts| lower.as_deref().is_none_or(|floor| ts > floor))
        } else {
            minimum
                .as_deref()
                .is_some_and(|ts| job.oldest.as_deref().is_none_or(|old| ts < old))
        };
        if !advancing {
            return Err(slack::error("pagination_stalled"));
        }
    }
    client.unchanged(&digest)?;
    for message in messages {
        store.upsert_message(&job.channel, &snapshot_entity(message, event_id)?)?;
    }
    store.with_conn(|c| {
        let tx = c.transaction()?;
        let complete = !has_more && cursor.is_empty();
        let oldest = if thread {
            if has_more && cursor.is_empty() { maximum.clone().or(job.oldest.clone()) } else { job.oldest.clone() }
        } else { minimum.clone().map(|ts| job.oldest.clone().map_or(ts.clone(), |old| old.min(ts))).or(job.oldest.clone()) };
        let newest = if thread { maximum.clone().map(|ts| job.newest.clone().map_or(ts.clone(), |old| old.max(ts))).or(job.newest.clone()) } else { job.newest.clone() };
        let latest = if !thread && has_more && cursor.is_empty() { minimum.clone() } else { job.latest.clone() };
        tx.execute("UPDATE sync_jobs SET cursor=?4,oldest_ts=?5,latest_ts=?6,newest_ts=?7,complete=?8,error=NULL,retry_at=0,updated_at=?9 WHERE kind=?1 AND channel_id=?2 AND thread_ts=?3", params![job.kind,job.channel,job.root,cursor,oldest,latest,newest,complete,now_ms()])?;
        if complete && matches!(job.kind.as_str(), "history" | "refresh") {
            meta_tx(&tx, &format!("history_full_refresh:{}", job.channel), &now_ms().to_string())?;
        }
        if thread && complete {
            if generation(&tx, &format!("thread_full_scan:{}:{}", job.channel, job.root))? == "true" {
                meta_tx(&tx, &format!("thread_full_refresh:{}:{}", job.channel, job.root), &now_ms().to_string())?;
            }
            let dirty = generation(&tx, &generation_key(&job.channel, &job.root))?;
            let scanned = generation(&tx, &scan_key(&job.channel, &job.root))?;
            if dirty != scanned {
                tx.execute("UPDATE sync_jobs SET complete=0,cursor=NULL,oldest_ts=latest_ts,latest_ts=NULL,newest_ts=NULL WHERE kind='thread' AND channel_id=?1 AND thread_ts=?2", params![job.channel,job.root])?;
            }
        }
        tx.commit()?;
        Ok(())
    })?;
    Ok(())
}
