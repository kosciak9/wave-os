use crate::store::Store;
use anyhow::{bail, Context, Result};
use rusqlite::{params, params_from_iter, types::Value as SqlValue, Connection, OptionalExtension};
use serde_json::{json, Value};

const BYTE_BUDGET: usize = 60 * 1024;

pub fn tools() -> Value {
    let pagination = json!({
        "limit":{"type":"integer","minimum":1,"maximum":100,"default":50},
        "cursor":{"type":"string","description":"Opaque next_cursor from the same tool and unchanged filters."},
        "max_text":{"type":"integer","minimum":0,"maximum":8000,"default":2000}
    });
    let definitions = [
        ("status", "Local mirror/auth/sync state and paginated observed coverage or individual sync jobs/errors. Completed known jobs do not imply all threads are known.", json!({"view":{"type":"string","enum":["conversations","jobs"]},"errors_only":{"type":"boolean"}}), vec![]),
        ("list_conversations", "List cached conversations and Slack read markers.", json!({"kind":{"type":"string","enum":["channel","private","im","mpim"]},"include_archived":{"type":"boolean"}}), vec![]),
        ("unread", "Messages newer than observed Slack channel or subscribed-thread read markers; read-only, never marks Slack read. Unknown markers are not treated as unread.", json!({"channel":{"type":"string"},"after":{"type":"string"},"before":{"type":"string"},"mode":{"type":"string","enum":["all","channel","thread"]}}), vec![]),
        ("get_conversation", "Cached conversation messages in ascending timestamp order, with tombstones and observed coverage.", json!({"channel":{"type":"string"},"after":{"type":"string"},"before":{"type":"string"}}), vec!["channel"]),
        ("get_thread", "Root on every page plus ascending replies. Missing root is reported explicitly; thread coverage is local only.", json!({"channel":{"type":"string"},"thread_ts":{"type":"string"}}), vec!["channel","thread_ts"]),
        ("search", "FTS5 MATCH search, ordered chronologically (no relevance ranking). Time accepts Slack/unix timestamps, RFC3339, or relative 30m/48h/14d.", json!({"query":{"type":"string","description":"FTS5 MATCH expression"},"channel":{"type":"string"},"sender":{"type":"string"},"mentions":{"type":"string"},"type":{"type":"string","enum":["message","thread","reply","file"]},"after":{"type":"string"},"before":{"type":"string"},"include_bots":{"type":"boolean"}}), vec!["query"]),
        ("users", "List cached user identities; optional exact id, @name, or email resolver.", json!({"user":{"type":"string"}}), vec![]),
        ("describe_schema", "Describe local tables and safe query semantics. No arbitrary SQL tool is available.", json!({}), vec![]),
    ];
    Value::Array(definitions.into_iter().map(|(name,description,mut properties,required)| {
        properties.as_object_mut().unwrap().extend(pagination.as_object().unwrap().clone());
        json!({"name":name,"description":description,"inputSchema":{"type":"object","properties":properties,"required":required,"additionalProperties":false},"annotations":{"readOnlyHint":true,"destructiveHint":false,"openWorldHint":false}})
    }).collect())
}

pub fn call(store: &Store, name: &str, args: &Value) -> Result<Value> {
    if !args.is_object() {
        bail!("tool arguments must be an object");
    }
    let page = Page::new(name, args)?;
    store.with_reader(|c| {
        let tx = c.transaction()?;
        let result = match name {
            "status" => status(&tx, args, &page)?,
            "list_conversations" => conversations(&tx, args, &page)?,
            "users" => users(&tx, args, &page)?,
            "get_conversation" | "get_thread" | "unread" | "search" => {
                messages(&tx, name, args, &page)?
            }
            "describe_schema" => schema(),
            _ => bail!("unknown tool: {name}"),
        };
        tx.commit()?;
        if mcp_envelope_size(&result)? > BYTE_BUDGET {
            bail!("response exceeds MCP envelope budget");
        }
        Ok(result)
    })
}

struct Page {
    limit: usize,
    max_text: usize,
    key: Vec<String>,
    scope: Value,
    anchor: i64,
}
impl Page {
    fn new(name: &str, args: &Value) -> Result<Self> {
        let limit = integer(args, "limit", 50, 1, 100)?;
        let max_text = integer(args, "max_text", 2000, 0, 8000)?;
        let mut filters = args.clone();
        filters.as_object_mut().unwrap().remove("cursor");
        if serde_json::to_vec(&filters)?.len() > 3500 {
            bail!("tool arguments exceed size limit");
        }
        let scope = json!({"tool":name,"args":filters});
        let mut anchor = chrono::Utc::now().timestamp();
        let key = if let Some(cursor) = optional(args, "cursor")? {
            if cursor.len() > 5000 {
                bail!("cursor too long");
            }
            let value: Value = serde_json::from_str(cursor).context("invalid cursor")?;
            if value["scope"] != scope {
                bail!("cursor must be used with the same tool and filters");
            }
            anchor = value["anchor"].as_i64().context("invalid cursor anchor")?;
            value["key"]
                .as_array()
                .context("invalid cursor key")?
                .iter()
                .map(|v| v.as_str().map(str::to_owned).context("invalid cursor key"))
                .collect::<Result<Vec<_>>>()?
        } else {
            vec![]
        };
        let expected_keys = match name {
            "get_conversation" | "get_thread" | "unread" | "search" => 2,
            "status" if args["view"].as_str() == Some("jobs") => 3,
            _ => 1,
        };
        if !key.is_empty() && key.len() != expected_keys {
            bail!("invalid cursor key");
        }
        Ok(Self {
            limit,
            max_text,
            key,
            scope,
            anchor,
        })
    }
    fn cursor(&self, key: &[String]) -> Value {
        json!({"scope":self.scope,"key":key,"anchor":self.anchor})
            .to_string()
            .into()
    }
    fn key(&self, index: usize) -> &str {
        self.key.get(index).map(String::as_str).unwrap_or("")
    }
}
fn integer(args: &Value, key: &str, default: usize, min: usize, max: usize) -> Result<usize> {
    let n = match args.get(key) {
        None => default,
        Some(v) => v.as_u64().context(format!("{key} must be an integer"))? as usize,
    };
    if n < min || n > max {
        bail!("{key} must be between {min} and {max}");
    }
    Ok(n)
}
fn optional<'a>(args: &'a Value, key: &str) -> Result<Option<&'a str>> {
    args.get(key)
        .map(|v| {
            v.as_str()
                .with_context(|| format!("{key} must be a string"))
        })
        .transpose()
}
fn required<'a>(args: &'a Value, key: &str) -> Result<&'a str> {
    optional(args, key)?
        .filter(|s| !s.is_empty())
        .with_context(|| format!("missing {key}"))
}
fn boolean(args: &Value, key: &str, default: bool) -> Result<bool> {
    args.get(key)
        .map(|v| {
            v.as_bool()
                .with_context(|| format!("{key} must be a boolean"))
        })
        .transpose()
        .map(|v| v.unwrap_or(default))
}
fn text(value: &Value, key: &str, max: usize) -> Value {
    value
        .get(key)
        .and_then(Value::as_str)
        .map(|s| Value::String(s.chars().take(max).collect()))
        .unwrap_or(Value::Null)
}
fn bound_text(s: &str, max: usize) -> String {
    s.chars().take(max).collect()
}

fn finish(page: &Page, candidates: Vec<(Vec<String>, Value)>, mut result: Value) -> Result<Value> {
    let mut items = Vec::new();
    let mut last = None;
    let mut more = false;
    for (key, value) in candidates {
        if items.len() >= page.limit {
            more = true;
            break;
        }
        items.push(value);
        result["items"] = json!(items);
        result["next_cursor"] = page.cursor(&key);
        if mcp_envelope_size(&result)? > BYTE_BUDGET {
            items.pop();
            if items.is_empty() {
                bail!("response metadata exceeds MCP page budget; reduce max_text");
            }
            more = true;
            break;
        }
        last = Some(key);
    }
    result["items"] = json!(items);
    result["next_cursor"] = if more {
        page.cursor(&last.context("missing page key")?)
    } else {
        Value::Null
    };
    if mcp_envelope_size(&result)? > BYTE_BUDGET {
        bail!("response exceeds page budget");
    }
    Ok(result)
}

fn mcp_envelope_size(result: &Value) -> Result<usize> {
    let envelope = json!({"jsonrpc":"2.0","id":null,"result":{"content":[{"type":"text","text":result.to_string()}],"structuredContent":result}});
    // The server limits the serialized request id to 512 bytes.
    Ok(serde_json::to_vec(&envelope)?.len() + 512)
}

fn resolve_user(c: &Connection, input: &str) -> Result<String> {
    let name = input.trim_start_matches('@');
    let mut stmt=c.prepare("SELECT id FROM users WHERE id=?1 OR json_extract(raw,'$.name')=?2 OR json_extract(raw,'$.profile.email')=?2 OR json_extract(raw,'$.profile.display_name')=?2 LIMIT 2")?;
    let ids = stmt
        .query_map(params![input, name], |r| r.get::<_, String>(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    match ids.as_slice() {
        [id] => Ok(id.clone()),
        [] if input.starts_with('U') || input.starts_with('W') => Ok(input.into()),
        [] => bail!("unknown user"),
        _ => bail!("ambiguous user; use id"),
    }
}
fn resolve_channel(c: &Connection, input: &str) -> Result<String> {
    if input.starts_with('@') || input.contains('@') {
        let uid = resolve_user(c, input)?;
        let id=c.query_row("SELECT id FROM conversations WHERE kind='im' AND json_extract(raw,'$.user')=?1 LIMIT 1",[uid],|r|r.get(0)).optional()?;
        return id.context("no cached direct conversation for user");
    }
    let mut stmt = c.prepare("SELECT id FROM conversations WHERE id=?1 OR name=?2 LIMIT 2")?;
    let ids = stmt
        .query_map(params![input, input.trim_start_matches('#')], |r| {
            r.get::<_, String>(0)
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    match ids.as_slice() {
        [id] => Ok(id.clone()),
        [] if input.starts_with('C') || input.starts_with('G') || input.starts_with('D') => {
            Ok(input.into())
        }
        [] => bail!("unknown conversation"),
        _ => bail!("ambiguous conversation; use id"),
    }
}

fn timestamp(input: &str, anchor: i64) -> Result<String> {
    let input = input.trim();
    if let Some(unit) = input
        .chars()
        .last()
        .filter(|u| matches!(u, 'm' | 'h' | 'd'))
    {
        let amount: i64 = input[..input.len() - 1]
            .parse()
            .context("invalid relative time")?;
        if amount < 0 {
            bail!("relative time must be nonnegative");
        }
        let seconds = amount
            .checked_mul(match unit {
                'm' => 60,
                'h' => 3600,
                _ => 86400,
            })
            .context("relative time overflow")?;
        let time = anchor
            .checked_sub(seconds)
            .context("relative time overflow")?;
        if time < 0 {
            bail!("time precedes unix epoch");
        }
        return Ok(format!("{time:010}.000000"));
    }
    if let Ok(date) = chrono::DateTime::parse_from_rfc3339(input) {
        if date.timestamp() < 0 {
            bail!("time precedes unix epoch");
        }
        return Ok(format!(
            "{:010}.{:06}",
            date.timestamp(),
            date.timestamp_subsec_micros()
        ));
    }
    let (whole, fraction) = input.split_once('.').unwrap_or((input, ""));
    if whole.is_empty()
        || !whole.bytes().all(|b| b.is_ascii_digit())
        || !fraction.bytes().all(|b| b.is_ascii_digit())
        || fraction.len() > 6
    {
        bail!("time must be Slack/unix seconds, RFC3339, or relative 30m/48h/14d");
    }
    let seconds: u64 = whole.parse()?;
    if seconds > 9_999_999_999 {
        bail!("unix time must be seconds, not milliseconds");
    }
    Ok(format!("{seconds:010}.{fraction:0<6}"))
}

fn coverage(c: &Connection, channel: &str, root: Option<&str>) -> Result<Value> {
    let sql = if root.is_some() {
        "SELECT kind,thread_ts,oldest_ts,latest_ts,newest_ts,complete,error,retry_at,updated_at FROM sync_jobs WHERE channel_id=?1 AND kind='thread' AND thread_ts=?2 LIMIT 1"
    } else {
        "SELECT kind,thread_ts,oldest_ts,latest_ts,newest_ts,complete,error,retry_at,updated_at FROM sync_jobs WHERE channel_id=?1 AND kind IN ('history','gap','refresh') ORDER BY kind LIMIT 3"
    };
    let mut stmt = c.prepare(sql)?;
    let jobs = if let Some(root) = root {
        stmt.query_map(params![channel, root], job_row)?
            .collect::<rusqlite::Result<Vec<_>>>()?
    } else {
        stmt.query_map([channel], job_row)?
            .collect::<rusqlite::Result<Vec<_>>>()?
    };
    let (known,incomplete):(i64,i64)=c.query_row("SELECT count(*),coalesce(sum(CASE WHEN complete=0 THEN 1 ELSE 0 END),0) FROM sync_jobs WHERE channel_id=?1 AND kind='thread'",[channel],|r|Ok((r.get(0)?,r.get(1)?)))?;
    let (oldest, newest): (Option<String>, Option<String>) = c.query_row(
        "SELECT (SELECT ts FROM messages WHERE channel_id=?1 ORDER BY ts LIMIT 1),(SELECT ts FROM messages WHERE channel_id=?1 ORDER BY ts DESC LIMIT 1)",
        [channel],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    Ok(
        json!({"jobs":jobs,"known_threads":known,"incomplete_known_threads":incomplete,"all_threads_known":false,"cached_oldest_ts":oldest,"cached_newest_ts":newest,"scope":"observed local cache only"}),
    )
}
fn safe_error(error: Option<String>) -> Option<String> {
    error.map(|s| {
        let lower = s.to_ascii_lowercase();
        if [
            "token",
            "cookie",
            "authorization",
            "xox",
            "secret",
            "password",
            "https://",
            "http://",
        ]
        .iter()
        .any(|needle| lower.contains(needle))
        {
            "sync error (sensitive details withheld)".into()
        } else {
            bound_text(&s, 500)
        }
    })
}
fn job_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<Value> {
    Ok(
        json!({"kind":r.get::<_,String>(0)?,"thread_ts":r.get::<_,String>(1)?,"oldest_ts":r.get::<_,Option<String>>(2)?,"latest_ts":r.get::<_,Option<String>>(3)?,"newest_ts":r.get::<_,Option<String>>(4)?,"complete":r.get::<_,bool>(5)?,"error":safe_error(r.get(6)?),"retry_at":r.get::<_,i64>(7)?,"updated_at":r.get::<_,i64>(8)?}),
    )
}

fn status(c: &Connection, args: &Value, page: &Page) -> Result<Value> {
    let mut meta = serde_json::Map::new();
    for key in [
        "workspace_id",
        "workspace_domain",
        "team_id",
        "user_id",
        "sync_state",
        "auth_state",
        "last_sync_at",
        "last_event_at",
        "last_connected_at",
        "last_disconnected_at",
        "sync_started_at",
        "rtm_state",
        "auth_error",
        "last_reconcile_at",
        "backfill_started_at",
        "engine_error",
        "offline",
        "projection_error",
        "catalog_reconcile_complete",
    ] {
        if let Some(value) = c
            .query_row("SELECT value FROM meta WHERE key=?1", [key], |r| {
                r.get::<_, String>(0)
            })
            .optional()?
        {
            let lower = value.to_ascii_lowercase();
            let value = if [
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
            {
                "[redacted]".into()
            } else {
                bound_text(&value, 500)
            };
            let value = if key.ends_with("error") {
                safe_error(Some(value)).unwrap_or_default()
            } else {
                value
            };
            meta.insert(key.into(), json!(value));
        }
    }
    for method in [
        "users.list",
        "users.conversations",
        "conversations.list",
        "client.counts",
        "client.userBoot",
        "subscriptions.thread.getView",
    ] {
        let key = format!("catalog:{method}");
        if let Some(raw) = c
            .query_row("SELECT value FROM meta WHERE key=?1", [&key], |r| {
                r.get::<_, String>(0)
            })
            .optional()?
        {
            let value: Value = serde_json::from_str(&raw)?;
            let mut progress = json!({});
            for field in ["complete", "unavailable", "has_cursor"] {
                if let Some(value) = value[field].as_bool() {
                    progress[field] = value.into();
                }
            }
            for field in ["pages", "attempted_at", "retry_at"] {
                if let Some(value) = value[field].as_i64() {
                    progress[field] = value.into();
                }
            }
            progress["error"] = json!(safe_error(value["error"].as_str().map(str::to_owned)));
            meta.insert(key, progress);
        }
    }
    let mut stmt=c.prepare("SELECT kind,complete,count(*),sum(CASE WHEN error IS NOT NULL THEN 1 ELSE 0 END) FROM sync_jobs GROUP BY kind,complete")?;
    let jobs=stmt.query_map([],|r|Ok(json!({"kind":r.get::<_,String>(0)?,"complete":r.get::<_,bool>(1)?,"count":r.get::<_,i64>(2)?,"errors":r.get::<_,i64>(3)?})))?.collect::<rusqlite::Result<Vec<_>>>()?;
    let view = optional(args, "view")?.unwrap_or("conversations");
    if view == "jobs" {
        let errors_only = boolean(args, "errors_only", false)?;
        let mut stmt = c.prepare("SELECT kind,thread_ts,oldest_ts,latest_ts,newest_ts,complete,error,retry_at,updated_at,channel_id FROM sync_jobs WHERE (kind,channel_id,thread_ts)>(?1,?2,?3) AND (?4=0 OR error IS NOT NULL) ORDER BY kind,channel_id,thread_ts LIMIT ?5")?;
        let items = stmt
            .query_map(
                params![
                    page.key(0),
                    page.key(1),
                    page.key(2),
                    errors_only,
                    (page.limit + 1) as i64
                ],
                |r| {
                    let mut value = job_row(r)?;
                    let channel: String = r.get(9)?;
                    let key = vec![r.get(0)?, channel.clone(), r.get(1)?];
                    value["channel_id"] = channel.into();
                    Ok((key, value))
                },
            )?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        return finish(
            page,
            items,
            json!({"meta":meta,"job_counts":jobs,"all_threads_known":false,"read_only":true}),
        );
    }
    if view != "conversations" {
        bail!("invalid status view");
    }
    let mut stmt =
        c.prepare("SELECT id,name FROM conversations WHERE id>?1 ORDER BY id LIMIT ?2")?;
    let rows = stmt
        .query_map(params![page.key(0), (page.limit + 1) as i64], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let mut items = vec![];
    for (id, name) in rows {
        let cov = coverage(c, &id, None)?;
        items.push((
            vec![id.clone()],
            json!({"id":id,"name":bound_text(&name,200),"coverage":cov}),
        ));
    }
    finish(
        page,
        items,
        json!({"meta":meta,"job_counts":jobs,"all_threads_known":false,"read_only":true}),
    )
}

fn conversation_value(c: &Connection, id: &str) -> Result<Value> {
    let row: Option<(String, String, bool, bool, String)> = c
        .query_row(
            "SELECT name,kind,is_member,is_archived,raw FROM conversations WHERE id=?1",
            [id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
        )
        .optional()?;
    let Some((name, kind, member, archived, raw)) = row else {
        return Ok(json!({"id":id,"cached":false}));
    };
    let raw: Value = serde_json::from_str(&raw)?;
    let read: Option<(Option<String>, Option<String>, Option<bool>)> = c
        .query_row(
            "SELECT last_read,latest,has_unreads FROM channel_reads WHERE channel_id=?1",
            [id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()?;
    Ok(
        json!({"id":id,"name":bound_text(&name,200),"kind":kind,"is_member":member,"is_archived":archived,"user_id":text(&raw,"user",100),"topic":text(&raw["topic"],"value",1000),"purpose":text(&raw["purpose"],"value",1000),"last_read":read.as_ref().and_then(|r|r.0.clone()),"latest":read.as_ref().and_then(|r|r.1.clone()),"has_unreads":read.and_then(|r|r.2)}),
    )
}
fn conversations(c: &Connection, args: &Value, page: &Page) -> Result<Value> {
    let kind = optional(args, "kind")?;
    if kind.is_some_and(|k| !["channel", "private", "im", "mpim"].contains(&k)) {
        bail!("invalid conversation kind");
    }
    let archived = boolean(args, "include_archived", false)?;
    let mut stmt=c.prepare("SELECT id FROM conversations WHERE id>?1 AND (?2 IS NULL OR kind=?2) AND (?3 OR is_archived=0) ORDER BY id LIMIT ?4")?;
    let ids = stmt
        .query_map(
            params![page.key(0), kind, archived, (page.limit + 1) as i64],
            |r| r.get::<_, String>(0),
        )?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let mut items = vec![];
    for id in ids {
        items.push((vec![id.clone()], conversation_value(c, &id)?));
    }
    finish(page, items, json!({}))
}
fn users(c: &Connection, args: &Value, page: &Page) -> Result<Value> {
    let id = optional(args, "user")?
        .map(|s| resolve_user(c, s))
        .transpose()?;
    let mut stmt = c.prepare(
        "SELECT id,raw FROM users WHERE id>?1 AND (?2 IS NULL OR id=?2) ORDER BY id LIMIT ?3",
    )?;
    let items=stmt.query_map(params![page.key(0),id,(page.limit+1) as i64],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?)))?.collect::<rusqlite::Result<Vec<_>>>()?.into_iter().map(|(id,raw)| {
        let v:Value=serde_json::from_str(&raw)?;
        Ok((vec![id.clone()],json!({"id":id,"name":text(&v,"name",200),"real_name":text(&v,"real_name",300),"display_name":text(&v["profile"],"display_name",300),"email":text(&v["profile"],"email",300),"deleted":v["deleted"].as_bool(),"is_bot":v["is_bot"].as_bool(),"timezone":text(&v,"tz",100)})))
    }).collect::<Result<Vec<_>>>()?;
    finish(page, items, json!({}))
}

fn permalink(c: &Connection, channel: &str, ts: &str) -> Result<Option<String>> {
    let domain: Option<String> = c
        .query_row(
            "SELECT value FROM meta WHERE key='workspace_domain'",
            [],
            |r| r.get(0),
        )
        .optional()?;
    let base = if let Some(domain) = domain {
        let base = if domain.contains("://") {
            domain
        } else if domain.contains('.') {
            format!("https://{domain}")
        } else {
            format!("https://{domain}.slack.com")
        };
        let url = url::Url::parse(&base).ok();
        url.filter(|u| {
            u.scheme() == "https"
                && u.host_str().is_some_and(|h| h.ends_with(".slack.com"))
                && u.username().is_empty()
                && u.password().is_none()
        })
        .map(|u| format!("https://{}", u.host_str().unwrap()))
    } else {
        let raw: Option<String> = c
            .query_row(
                "SELECT raw FROM conversations WHERE id=?1",
                [channel],
                |r| r.get(0),
            )
            .optional()?;
        raw.and_then(|s| serde_json::from_str::<Value>(&s).ok())
            .and_then(|v| v["url"].as_str().map(str::to_owned))
            .and_then(|s| url::Url::parse(&s).ok())
            .filter(|u| {
                u.scheme() == "https" && u.host_str().is_some_and(|h| h.ends_with(".slack.com"))
            })
            .map(|u| format!("https://{}", u.host_str().unwrap()))
    };
    Ok(base.map(|b| format!("{b}/archives/{channel}/p{}", ts.replace('.', ""))))
}
type MessageRow = (
    String,
    String,
    Option<String>,
    Option<String>,
    String,
    String,
    bool,
);
fn message_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<MessageRow> {
    Ok((
        r.get(0)?,
        r.get(1)?,
        r.get(2)?,
        r.get(3)?,
        r.get(4)?,
        r.get(5)?,
        r.get(6)?,
    ))
}
fn message_value(c: &Connection, row: MessageRow, max_text: usize) -> Result<Value> {
    let (channel, ts, thread, user, body, raw, deleted) = row;
    let v: Value = serde_json::from_str(&raw)?;
    let mut stmt=c.prepare("SELECT name,user_id FROM reactions WHERE channel_id=?1 AND ts=?2 ORDER BY name,user_id LIMIT 101")?;
    let reactions=stmt.query_map(params![channel,ts],|r|Ok(json!({"name":bound_text(&r.get::<_,String>(0)?,100),"user_id":bound_text(&r.get::<_,String>(1)?,100)})))?.collect::<rusqlite::Result<Vec<_>>>()?;
    let reactions_truncated = reactions.len() > 100;
    let mut files = Vec::new();
    if let Some(attached) = v["files"].as_array() {
        for attachment in attached.iter().take(10) {
            let stored: Option<(String, bool)> = if let Some(id) = attachment["id"].as_str() {
                c.query_row("SELECT raw,deleted FROM files WHERE id=?1", [id], |r| {
                    Ok((r.get(0)?, r.get(1)?))
                })
                .optional()?
            } else {
                None
            };
            let (file, deleted) = match stored {
                Some((raw, deleted)) => (serde_json::from_str::<Value>(&raw)?, deleted),
                None => (attachment.clone(), false),
            };
            files.push(json!({"id":text(&file,"id",100),"name":text(&file,"name",300),"title":text(&file,"title",300),"mimetype":text(&file,"mimetype",100),"deleted":deleted}));
        }
    }
    let edits: i64 = c.query_row(
        "SELECT count(*) FROM message_edits WHERE channel_id=?1 AND ts=?2",
        params![channel, ts],
        |r| r.get(0),
    )?;
    let mut value = json!({
        "channel_id":channel,"ts":ts,"thread_ts":thread,"user_id":user,
        "text":if deleted {String::new()} else {bound_text(&body,max_text)},
        "text_truncated":!deleted && body.chars().count()>max_text,"deleted":deleted,
        "subtype":text(&v,"subtype",100),"bot_id":text(&v,"bot_id",100),
        "reply_count":v["reply_count"].as_u64(),"edited_ts":text(&v["edited"],"ts",30),
        "preserved_edit_count":edits,"permalink":permalink(c,&channel,&ts)?,
        "reactions":reactions.into_iter().take(100).collect::<Vec<_>>(),
        "reactions_truncated":reactions_truncated,"reactions_known_users_only":true,"files":files,
        "files_truncated":v["files"].as_array().is_some_and(|f|f.len()>10)
    });
    // A single very large message must not make a keyset page impossible to advance.
    compact_message(&mut value, 16 * 1024)?;
    Ok(value)
}

fn compact_message(value: &mut Value, budget: usize) -> Result<()> {
    while mcp_envelope_size(value)? > budget {
        let body = value["text"].as_str().unwrap_or("");
        if !body.is_empty() {
            value["text"] = bound_text(body, body.chars().count() / 2).into();
            value["text_truncated"] = true.into();
        } else if !value["reactions"].as_array().unwrap().is_empty() {
            value["reactions"].as_array_mut().unwrap().pop();
            value["reactions_truncated"] = true.into();
        } else if !value["files"].as_array().unwrap().is_empty() {
            value["files"].as_array_mut().unwrap().pop();
            value["files_truncated"] = true.into();
        } else {
            bail!("message identity exceeds response budget");
        }
    }
    Ok(())
}

fn messages(c: &Connection, name: &str, args: &Value, page: &Page) -> Result<Value> {
    let channel = optional(args, "channel")?
        .map(|s| resolve_channel(c, s))
        .transpose()?;
    if matches!(name, "get_conversation" | "get_thread") && channel.is_none() {
        bail!("channel is required");
    }
    let root = if name == "get_thread" {
        Some(timestamp(required(args, "thread_ts")?, page.anchor)?)
    } else {
        None
    };
    let mut result = json!({"order":"timestamp_ascending","scope":"observed local cache only"});
    if let Some(ch) = &channel {
        result["conversation"] = conversation_value(c, ch)?;
        result["coverage"] = coverage(c, ch, root.as_deref())?;
    }
    if let Some(root) = &root {
        let ch = channel.as_ref().unwrap();
        let row=c.query_row("SELECT channel_id,ts,thread_ts,user_id,coalesce(text,''),raw,deleted FROM messages WHERE channel_id=?1 AND ts=?2",params![ch,root],message_row).optional()?;
        // Reserve room for at least one reply even when the caller requests long text.
        result["root"] = row
            .map(|row| message_value(c, row, page.max_text.min(2000)))
            .transpose()?
            .unwrap_or(Value::Null);
        if !result["root"].is_null() {
            compact_message(&mut result["root"], 8 * 1024)?;
        }
        result["root_missing"] = result["root"].is_null().into();
        let read:Option<(Option<String>,Option<bool>)>=c.query_row("SELECT last_read,subscribed FROM thread_reads WHERE channel_id=?1 AND thread_ts=?2",params![ch,root],|r|Ok((r.get(0)?,r.get(1)?))).optional()?;
        result["thread_read"] = json!({"last_read":read.as_ref().and_then(|r|r.0.clone()),"subscribed":read.and_then(|r|r.1)});
    }
    let mut sql=String::from("SELECT m.channel_id,m.ts,m.thread_ts,m.user_id,coalesce(m.text,''),m.raw,m.deleted FROM messages m ");
    let mut conditions = vec!["(m.ts,m.channel_id)>(?,?)".to_owned()];
    let mut values = vec![
        SqlValue::Text(page.key(0).into()),
        SqlValue::Text(page.key(1).into()),
    ];
    if name == "search" {
        let query = required(args, "query")?;
        if query.len() > 2000 {
            bail!("search expression too long");
        }
        sql.push_str("JOIN messages_fts ON messages_fts.rowid=m.rowid ");
        conditions.push("messages_fts MATCH ?".into());
        values.push(query.to_owned().into());
    }
    if name == "unread" {
        sql.push_str("LEFT JOIN channel_reads cr ON cr.channel_id=m.channel_id LEFT JOIN thread_reads tr ON tr.channel_id=m.channel_id AND tr.thread_ts=m.thread_ts ");
        let channel_unread = "(cr.last_read IS NOT NULL AND m.ts>cr.last_read)";
        let thread_unread = "(tr.subscribed=1 AND tr.last_read IS NOT NULL AND m.ts>tr.last_read AND m.ts<>tr.thread_ts)";
        let condition = match optional(args, "mode")?.unwrap_or("all") {
            "all" => format!("({channel_unread} OR {thread_unread})"),
            "channel" => channel_unread.into(),
            "thread" => thread_unread.into(),
            _ => bail!("invalid unread mode"),
        };
        conditions.push(condition);
        conditions.push("m.deleted=0".into());
        result["unread_basis"]=json!("observed Slack channel last_read and subscribed thread last_read; unknown markers excluded");
    }
    if name == "search" {
        conditions.push("m.deleted=0".into());
    }
    if let Some(ch) = channel {
        conditions.push("m.channel_id=?".into());
        values.push(ch.into());
    }
    if let Some(root) = root {
        conditions.push("m.thread_ts=? AND m.ts<>?".into());
        values.push(root.clone().into());
        values.push(root.into());
    }
    for (key, op) in [("after", ">"), ("before", "<")] {
        if let Some(time) = optional(args, key)? {
            conditions.push(format!("m.ts{op}?"));
            values.push(timestamp(time, page.anchor)?.into());
        }
    }
    if let Some(sender) = optional(args, "sender")? {
        conditions.push("m.user_id=?".into());
        values.push(resolve_user(c, sender)?.into());
    }
    if let Some(mention) = optional(args, "mentions")? {
        conditions.push("instr(m.text,?)>0".into());
        values.push(format!("<@{}>", resolve_user(c, mention)?).into());
    }
    if !boolean(args, "include_bots", true)? {
        conditions.push("json_extract(m.raw,'$.bot_id') IS NULL AND coalesce((SELECT json_extract(u.raw,'$.is_bot') FROM users u WHERE u.id=m.user_id),0)=0".into());
    }
    if let Some(kind) = optional(args, "type")? {
        conditions.push(match kind {
            "message"=>"coalesce(json_extract(m.raw,'$.subtype'),'') IN ('','bot_message')",
            "thread"=>"coalesce(json_extract(m.raw,'$.reply_count'),0)>0 AND (m.thread_ts IS NULL OR m.thread_ts=m.ts)",
            "reply"=>"m.thread_ts IS NOT NULL AND m.thread_ts<>m.ts",
            "file"=>"coalesce(json_array_length(json_extract(m.raw,'$.files')),0)>0",
            _=>bail!("invalid message type"),
        }.into());
    }
    sql.push_str("WHERE ");
    sql.push_str(&conditions.join(" AND "));
    sql.push_str(" ORDER BY m.ts,m.channel_id LIMIT ?");
    values.push(((page.limit + 1) as i64).into());
    let mut stmt = c.prepare(&sql)?;
    let rows = stmt
        .query_map(params_from_iter(values), message_row)?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let mut items = vec![];
    for row in rows {
        let key = vec![row.1.clone(), row.0.clone()];
        items.push((key, message_value(c, row, page.max_text)?));
    }
    finish(page, items, result)
}

fn schema() -> Value {
    json!({"schema_version":1,"timestamps":"Slack fixed-width seconds.microseconds; captured_at/received_at/retry_at/updated_at are Unix milliseconds","tables":{
        "meta":["key","value"],"users":["id","raw"],"conversations":["id","name","kind","is_member","is_archived","raw"],
        "messages":["channel_id","ts","thread_ts","user_id","text","raw","deleted"],"message_edits":["id","channel_id","ts","raw","captured_at"],
        "events":["id","received_at","event_type","raw"],"reactions":["channel_id","ts","name","user_id"],"files":["id","raw","deleted"],
        "channel_reads":["channel_id","last_read","latest","has_unreads","raw"],"thread_reads":["channel_id","thread_ts","last_read","subscribed","raw"],
        "sync_jobs":["kind","channel_id","thread_ts","cursor","oldest_ts","latest_ts","newest_ts","complete","error","retry_at","updated_at"]},
        "search":"FTS5 MATCH over live nondeleted text, bind parameters, chronological order","pagination":"stable keysets; same arguments with next_cursor; up to 100 items and 60KiB serialized MCP envelope including text and structuredContent","raw_sql":false,"raw_payloads_exposed":false,"coverage":"only observed conversations and known threads; incomplete jobs and cached ranges are not proof of complete workspace coverage","retention":"events, prior edits and deletion tombstones retained indefinitely"})
}
