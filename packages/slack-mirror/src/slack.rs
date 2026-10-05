use crate::{
    session::{cookie_header, load_session, Session},
    store::Store,
};
use anyhow::{bail, Result};
use reqwest::{redirect::Policy, Client};
use rusqlite::{params, OptionalExtension};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{collections::HashMap, fmt, path::PathBuf, sync::Arc, time::Duration};
use tokio::sync::Mutex;

#[derive(Debug)]
pub struct ApiError {
    pub code: &'static str,
    pub retry_after: Duration,
}
impl fmt::Display for ApiError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.code)
    }
}
impl std::error::Error for ApiError {}
pub(crate) fn error(code: &'static str) -> anyhow::Error {
    ApiError {
        code,
        retry_after: Duration::ZERO,
    }
    .into()
}
pub(crate) fn auth_error(e: &anyhow::Error) -> bool {
    e.downcast_ref::<ApiError>().is_some_and(|e| {
        matches!(
            e.code,
            "invalid_auth"
                | "not_authed"
                | "token_revoked"
                | "token_expired"
                | "account_inactive"
                | "identity_mismatch"
                | "invalid_identity"
                | "session_unavailable"
                | "invalid_domain"
        )
    })
}
pub(crate) fn code(e: &anyhow::Error) -> &'static str {
    e.downcast_ref::<ApiError>()
        .map(|e| e.code)
        .unwrap_or("engine_failure")
}

const READ_METHODS: &[&str] = &[
    "auth.test",
    "client.counts",
    "client.userBoot",
    "conversations.history",
    "conversations.info",
    "conversations.list",
    "conversations.replies",
    "rtm.connect",
    "subscriptions.thread.getView",
    "users.conversations",
    "users.list",
];

#[derive(Default)]
struct IdentityGate {
    store: Option<Store>,
    verified: Option<[u8; 32]>,
}

#[derive(Clone)]
pub struct SlackClient {
    http: Client,
    session_file: Arc<PathBuf>,
    gate: Arc<Mutex<IdentityGate>>,
    cooldowns: Arc<Mutex<HashMap<String, tokio::time::Instant>>>,
}

pub(crate) fn fingerprint(session: &Session) -> [u8; 32] {
    let mut hash = Sha256::new();
    for field in [
        session.token.as_str(),
        session.cookie.as_str(),
        session.domain.as_str(),
        session.team_id.as_deref().unwrap_or(""),
    ] {
        hash.update((field.len() as u64).to_be_bytes());
        hash.update(field.as_bytes());
    }
    hash.finalize().into()
}

fn domain(session: &Session) -> Result<String> {
    let input = session.domain.trim();
    let host = if input.contains('.') {
        input.to_owned()
    } else {
        format!("{input}.slack.com")
    };
    let slug = host
        .strip_suffix(".slack.com")
        .ok_or_else(|| error("invalid_domain"))?;
    if slug.is_empty()
        || slug.len() > 63
        || !slug.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
        || slug.starts_with('-')
        || slug.ends_with('-')
    {
        return Err(error("invalid_domain"));
    }
    Ok(host.to_ascii_lowercase())
}

impl SlackClient {
    pub fn new(session_file: PathBuf) -> Result<Self> {
        let http = Client::builder()
            .redirect(Policy::none())
            .timeout(Duration::from_secs(30))
            .connect_timeout(Duration::from_secs(10))
            .build()
            .map_err(|_| error("http_setup_failed"))?;
        Ok(Self {
            http,
            session_file: Arc::new(session_file),
            gate: Arc::new(Mutex::new(IdentityGate::default())),
            cooldowns: Arc::new(Mutex::new(HashMap::new())),
        })
    }

    pub(crate) fn session(&self) -> Result<Session> {
        let session = load_session(&self.session_file).map_err(|_| error("session_unavailable"))?;
        domain(&session)?;
        Ok(session)
    }

    pub(crate) fn unchanged(&self, expected: &[u8; 32]) -> Result<()> {
        if &fingerprint(&self.session()?) != expected {
            return Err(error("session_changed"));
        }
        Ok(())
    }

    pub(crate) async fn bind(&self, store: Store) -> Result<()> {
        let mut gate = self.gate.lock().await;
        gate.store = Some(store);
        gate.verified = None;
        drop(gate);
        self.checked_session().await?;
        Ok(())
    }

    pub(crate) async fn checked_session(&self) -> Result<Session> {
        let mut gate = self.gate.lock().await;
        let session = self.session()?;
        let digest = fingerprint(&session);
        if gate.verified != Some(digest) {
            gate.verified = None;
            let identity = self.request(&session, "auth.test", &[]).await?;
            self.unchanged(&digest)?;
            let team = identity["team_id"]
                .as_str()
                .filter(|s| {
                    s.starts_with('T')
                        && s.len() <= 32
                        && s.bytes().all(|b| b.is_ascii_alphanumeric())
                })
                .ok_or_else(|| error("invalid_identity"))?;
            let user = identity["user_id"]
                .as_str()
                .filter(|s| {
                    (s.starts_with('U') || s.starts_with('W'))
                        && s.len() <= 32
                        && s.bytes().all(|b| b.is_ascii_alphanumeric())
                })
                .ok_or_else(|| error("invalid_identity"))?;
            if session.team_id.as_deref().is_some_and(|id| id != team) {
                return Err(error("identity_mismatch"));
            }
            if let Some(store) = &gate.store {
                store.with_conn(|c| {
                    let tx = c.transaction()?;
                    for (key, expected) in [("team_id", team), ("user_id", user)] {
                        let prior: Option<String> = tx.query_row("SELECT value FROM meta WHERE key=?1", [key], |r| r.get(0)).optional()?;
                        if prior.as_deref().is_some_and(|id| id != expected) { return Err(error("identity_mismatch")); }
                    }
                    let pinned: i64 = tx.query_row("SELECT count(*) FROM meta WHERE key IN ('team_id','user_id')", [], |r| r.get(0))?;
                    if pinned != 2 {
                        let populated: bool = tx.query_row("SELECT EXISTS(SELECT 1 FROM messages UNION ALL SELECT 1 FROM conversations UNION ALL SELECT 1 FROM users UNION ALL SELECT 1 FROM events)", [], |r| r.get(0))?;
                        if populated { return Err(error("identity_mismatch")); }
                    }
                    for (key, value) in [("team_id", team), ("workspace_id", team), ("user_id", user), ("workspace_domain", &domain(&session)?)] {
                        tx.execute("INSERT INTO meta(key,value) VALUES(?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value", params![key,value])?;
                    }
                    tx.commit()?;
                    Ok(())
                })?;
                store.set_meta("auth_error", "")?;
                store.set_meta("auth_state", "verified")?;
            }
            gate.verified = Some(digest);
        }
        Ok(session)
    }

    pub(crate) async fn call_checked(
        &self,
        method: &str,
        fields: &[(String, String)],
    ) -> Result<(Value, [u8; 32])> {
        if !READ_METHODS.contains(&method) {
            bail!(error("method_forbidden"));
        }
        let session = self.checked_session().await?;
        let digest = fingerprint(&session);
        let value = self.request(&session, method, fields).await?;
        self.unchanged(&digest)?;
        Ok((value, digest))
    }

    async fn request(
        &self,
        session: &Session,
        method: &str,
        fields: &[(String, String)],
    ) -> Result<Value> {
        if !READ_METHODS.contains(&method)
            || fields
                .iter()
                .any(|(k, _)| matches!(k.as_str(), "token" | "cookie" | "authorization"))
        {
            return Err(error("method_forbidden"));
        }
        if let Some(deadline) = self.cooldowns.lock().await.get(method).copied() {
            let wait = deadline.saturating_duration_since(tokio::time::Instant::now());
            if !wait.is_zero() {
                return Err(ApiError {
                    code: "ratelimited",
                    retry_after: wait,
                }
                .into());
            }
        }
        let mut form = vec![("token".to_owned(), session.token.clone())];
        form.extend_from_slice(fields);
        let mut response = self
            .http
            .post(format!("https://{}/api/{method}", domain(session)?))
            .header("Cookie", cookie_header(&session.cookie))
            .header("Origin", "https://app.slack.com")
            .form(&form)
            .send()
            .await
            .map_err(|_| error("transport_failed"))?;
        let retry = response
            .headers()
            .get("retry-after")
            .and_then(|s| s.to_str().ok())
            .and_then(|s| s.parse::<u64>().ok())
            .unwrap_or(30)
            .clamp(1, 86400);
        if response.status().as_u16() == 429 {
            return self.rate_limit(method, retry).await;
        }
        if !response.status().is_success() {
            return Err(error("http_failed"));
        }
        const MAX_PAYLOAD: usize = 8 * 1024 * 1024;
        if response
            .content_length()
            .is_some_and(|n| n > MAX_PAYLOAD as u64)
        {
            return Err(error("payload_too_large"));
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|_| error("transport_failed"))?
        {
            if chunk.len() > MAX_PAYLOAD.saturating_sub(bytes.len()) {
                return Err(error("payload_too_large"));
            }
            bytes.extend_from_slice(&chunk);
        }
        let value: Value = serde_json::from_slice(&bytes).map_err(|_| error("decode_failed"))?;
        if value["ok"].as_bool() != Some(true) {
            let code = match value["error"].as_str().unwrap_or("") {
                "ratelimited" => return self.rate_limit(method, retry).await,
                "invalid_auth" => "invalid_auth",
                "not_authed" => "not_authed",
                "token_revoked" => "token_revoked",
                "token_expired" => "token_expired",
                "account_inactive" => "account_inactive",
                "invalid_cursor" => "invalid_cursor",
                "channel_not_found" => "channel_not_found",
                "not_in_channel" => "not_in_channel",
                "thread_not_found" => "thread_not_found",
                "missing_scope" => "missing_scope",
                "access_denied" => "access_denied",
                "not_allowed_token_type" => "unsupported_session",
                "unknown_method" => "unknown_method",
                _ => "api_error",
            };
            return Err(error(code));
        }
        Ok(value)
    }

    async fn rate_limit<T>(&self, method: &str, seconds: u64) -> Result<T> {
        let retry_after = Duration::from_secs(seconds);
        self.cooldowns
            .lock()
            .await
            .insert(method.to_owned(), tokio::time::Instant::now() + retry_after);
        Err(ApiError {
            code: "ratelimited",
            retry_after,
        }
        .into())
    }
}
