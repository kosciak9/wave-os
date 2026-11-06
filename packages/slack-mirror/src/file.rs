use crate::{
    slack::{self, error, ApiError, SlackClient},
    store::Store,
};
use anyhow::Result;
use base64::{engine::general_purpose::STANDARD, Engine};
use rusqlite::{params, OptionalExtension};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

fn arguments(args: &Value) -> Result<(&str, &str, &str)> {
    let object = args.as_object().ok_or_else(|| error("invalid_arguments"))?;
    if object.len() != 3
        || !["channel", "ts", "file_id"]
            .iter()
            .all(|key| object.contains_key(*key))
    {
        return Err(error("invalid_arguments"));
    }
    let string = |key| args[key].as_str().ok_or_else(|| error("invalid_arguments"));
    let channel = string("channel")?;
    let ts = string("ts")?;
    let file = string("file_id")?;
    let id = |value: &str| {
        (2..=64).contains(&value.len()) && value.bytes().all(|b| b.is_ascii_alphanumeric())
    };
    if !id(channel)
        || !matches!(channel.as_bytes()[0], b'C' | b'G' | b'D')
        || !id(file)
        || !file.starts_with('F')
        || ts.len() != 17
        || !ts.bytes().enumerate().all(|(i, b)| {
            if i == 10 {
                b == b'.'
            } else {
                b.is_ascii_digit()
            }
        })
    {
        return Err(error("invalid_arguments"));
    }
    Ok((channel, ts, file))
}

async fn authorize(store: &Store, args: &Value) -> Result<()> {
    let (channel, ts, file) = arguments(args)?;
    let (channel, ts, file) = (channel.to_owned(), ts.to_owned(), file.to_owned());
    let store = store.clone();
    tokio::task::spawn_blocking(move || {
        store.with_reader(|c| {
            let tx = c.transaction()?;
            let message: Option<(String, bool)> = tx
                .query_row(
                    "SELECT raw,deleted FROM messages WHERE channel_id=?1 AND ts=?2",
                    params![channel, ts],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .optional()?;
            let Some((raw, deleted)) = message else {
                return Err(error("file_not_in_archive"));
            };
            if deleted {
                return Err(error("file_deleted"));
            }
            let raw: Value = serde_json::from_str(&raw)?;
            if !raw["files"]
                .as_array()
                .is_some_and(|files| files.iter().any(|f| f["id"].as_str() == Some(&file)))
            {
                return Err(error("file_not_in_archive"));
            }
            let deleted: Option<bool> = tx
                .query_row("SELECT deleted FROM files WHERE id=?1", [file], |r| {
                    r.get(0)
                })
                .optional()?;
            if deleted == Some(true) {
                return Err(error("file_deleted"));
            }
            tx.commit()?;
            Ok(())
        })
    })
    .await
    .map_err(|_| error("archive_unavailable"))?
}

async fn download(store: &Store, client: Option<&SlackClient>, args: &Value) -> Result<Value> {
    authorize(store, args).await?;
    let client = client.ok_or_else(|| error("offline"))?;
    let (_, _, id) = arguments(args)?;
    let (file, bytes) = client.download_file(id).await?;
    // A deletion or edit observed during the download revokes archive access.
    authorize(store, args).await?;
    let mime = file["mimetype"]
        .as_str()
        .filter(|s| !s.is_empty())
        .unwrap_or("application/octet-stream");
    let name = file["name"]
        .as_str()
        .filter(|s| !s.is_empty())
        .unwrap_or(id);
    let sha256: String = Sha256::digest(&bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    Ok(json!({"content":[{"type":"resource","resource":{
        "uri":format!("slack-file://{id}"),"mimeType":mime,"blob":STANDARD.encode(&bytes)},
        "_meta":{"filename":name,"size":bytes.len(),"sha256":sha256}}]}))
}

pub async fn call(store: &Store, client: Option<&SlackClient>, args: &Value) -> Value {
    match download(store, client, args).await {
        Ok(value) => value,
        Err(e) => {
            let code = slack::code(&e);
            let (code, explanation) = match code {
                "file_not_in_archive" => (
                    code,
                    "file is not attached to an archived message".to_owned(),
                ),
                "file_deleted" => (code, "file or archived message is deleted".to_owned()),
                "offline" => (code, "downloads need the online mirror".to_owned()),
                "invalid_arguments" => (
                    code,
                    "expected channel, ts and file_id with valid Slack identifiers".to_owned(),
                ),
                "too_large" => (code, "original file exceeds the 25 MiB limit".to_owned()),
                "size_mismatch" => (
                    code,
                    "download size does not match fresh Slack metadata".to_owned(),
                ),
                "download_not_authorized" => (
                    code,
                    "Slack did not authorize the original file download".to_owned(),
                ),
                "ratelimited" | "request_deferred" => {
                    let retry = e
                        .downcast_ref::<ApiError>()
                        .map(|e| {
                            e.retry_after
                                .as_secs()
                                .saturating_add(u64::from(e.retry_after.subsec_nanos() != 0))
                        })
                        .unwrap_or(1)
                        .max(1);
                    ("ratelimited", format!("retry after {retry} seconds"))
                }
                "transport_failed" => (code, "Slack file transfer failed".to_owned()),
                "engine_failure" | "archive_unavailable" => (
                    "archive_unavailable",
                    "local archive unavailable".to_owned(),
                ),
                _ => (code, "Slack file request could not be completed".to_owned()),
            };
            json!({"isError":true,"content":[{"type":"text","text":format!("get_file failed: {code}: {explanation}")}]})
        }
    }
}
