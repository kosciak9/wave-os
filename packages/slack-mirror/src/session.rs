use anyhow::{bail, Context, Result};
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    fs::{self, OpenOptions},
    io::{Read, Write},
    os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
    path::Path,
    time::Duration,
};
use tokio_tungstenite::{connect_async, tungstenite::Message};
use url::Url;

#[derive(Clone, Deserialize, Serialize)]
pub struct Session {
    pub token: String,
    pub cookie: String,
    pub domain: String,
    #[serde(rename = "teamId", alias = "team_id", default)]
    pub team_id: Option<String>,
}

pub fn validate_domain(domain: &str) -> Result<()> {
    if domain.is_empty()
        || domain.len() > 63
        || !domain
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
        || domain.starts_with('-')
        || domain.ends_with('-')
    {
        bail!("workspace must be a Slack workspace domain, not a URL");
    }
    Ok(())
}

pub fn read_private(path: &Path) -> Result<Vec<u8>> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .context("cannot open private credential file")?;
    let metadata = file.metadata()?;
    if !metadata.is_file()
        || metadata.permissions().mode() & 0o077 != 0
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.nlink() != 1
        || metadata.len() > 512_000
    {
        bail!("credential must be an owned private regular file (0600)");
    }
    let mut bytes = Vec::new();
    file.take(512_001).read_to_end(&mut bytes)?;
    if bytes.is_empty() || bytes.len() > 512_000 {
        bail!("invalid credential file size");
    }
    Ok(bytes)
}

pub fn load_session(path: &Path) -> Result<Session> {
    let session: Session = serde_json::from_slice(&read_private(path)?)
        .map_err(|_| anyhow::anyhow!("invalid Slack session JSON"))?;
    validate_domain(&session.domain)?;
    if !session.token.starts_with("xoxc-")
        || session.token.len() > 16_384
        || session.token.bytes().any(|b| !b.is_ascii_graphic())
        || session.cookie.is_empty()
        || session.cookie.len() > 65_536
        || session.cookie.chars().any(char::is_control)
    {
        bail!("invalid Slack web-session credentials");
    }
    Ok(session)
}

pub fn load_mcp_token(path: &Path) -> Result<String> {
    let token = String::from_utf8(read_private(path)?)
        .map_err(|_| anyhow::anyhow!("invalid MCP token encoding"))?;
    let token = token.trim();
    if token.len() < 32 || token.len() > 512 || !token.bytes().all(|b| b.is_ascii_graphic()) {
        bail!("MCP token must contain 32–512 non-whitespace ASCII characters");
    }
    Ok(token.to_owned())
}

pub fn cookie_header(cookie: &str) -> String {
    let value: String = url::form_urlencoded::byte_serialize(cookie.as_bytes()).collect();
    format!("d={}", value.replace('+', "%20"))
}

fn loopback_url(value: &str, websocket: bool) -> Result<Url> {
    let url = Url::parse(value).context("invalid local CDP URL")?;
    if url.scheme() != if websocket { "ws" } else { "http" }
        || !matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "[::1]"))
        || !url.username().is_empty()
        || url.password().is_some()
    {
        bail!("CDP must use an uncredentialed loopback URL");
    }
    Ok(url)
}

pub async fn capture(workspace: &str, endpoint: &str, output: &Path) -> Result<()> {
    validate_domain(workspace)?;
    let base = loopback_url(endpoint, false)?;
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(20))
        .build()?;
    let version: Value = client
        .get(base.join("/json/version")?)
        .send()
        .await
        .map_err(|_| anyhow::anyhow!("cannot reach local Chrome CDP"))?
        .json()
        .await
        .map_err(|_| anyhow::anyhow!("invalid Chrome CDP response"))?;
    let ws_url = loopback_url(
        version["webSocketDebuggerUrl"]
            .as_str()
            .context("Chrome CDP browser endpoint missing")?,
        true,
    )?;
    if ws_url.port_or_known_default() != base.port_or_known_default() {
        bail!("Chrome returned a different CDP port");
    }
    let (mut socket, _) = connect_async(ws_url.as_str())
        .await
        .map_err(|_| anyhow::anyhow!("cannot connect to Chrome CDP"))?;
    let mut id = 0u64;
    macro_rules! cdp {
        ($method:expr, $params:expr, $session:expr) => {{
            id += 1;
            let mut request = json!({"id": id, "method": $method, "params": $params});
            if let Some(session) = $session { request["sessionId"] = json!(session); }
            socket.send(Message::Text(request.to_string().into())).await
                .map_err(|_| anyhow::anyhow!("CDP connection closed"))?;
            tokio::time::timeout(Duration::from_secs(20), async {
                loop {
                    let frame = socket.next().await.context("CDP connection closed")?
                        .map_err(|_| anyhow::anyhow!("CDP connection failed"))?;
                    if let Message::Text(text) = frame {
                        let response: Value = serde_json::from_str(&text).map_err(|_| anyhow::anyhow!("invalid CDP response"))?;
                        if response["id"].as_u64() == Some(id) {
                            if response.get("error").is_some() { bail!("Chrome rejected CDP operation"); }
                            break Ok::<Value, anyhow::Error>(response["result"].clone());
                        }
                    }
                }
            }).await.context("Chrome CDP timed out")??
        }};
    }
    let targets = cdp!("Target.getTargets", json!({}), None::<&str>);
    let pages: Vec<_> = targets["targetInfos"]
        .as_array()
        .context("Chrome targets missing")?
        .iter()
        .filter(|t| {
            t["type"] == "page"
                && t["url"]
                    .as_str()
                    .is_some_and(|s| s.starts_with("https://app.slack.com/client/"))
        })
        .collect();
    let mut found = None;
    let mut chosen_target_session = None;
    for page in pages {
        let target = page["targetId"]
            .as_str()
            .context("Chrome target id missing")?;
        let attached = cdp!(
            "Target.attachToTarget",
            json!({"targetId":target,"flatten":true}),
            None::<&str>
        );
        let session_id = attached["sessionId"]
            .as_str()
            .context("Chrome target session missing")?;
        let expression = format!("JSON.stringify((() => {{ const t = Object.values(JSON.parse(localStorage.localConfig_v2 || '{{}}').teams || {{}}).find(t => t.domain === {}); return t ? {{domain:t.domain,token:t.token,teamId:t.id}} : null; }})())", serde_json::to_string(workspace)?);
        let result = cdp!(
            "Runtime.evaluate",
            json!({"expression":expression,"returnByValue":true}),
            Some(session_id)
        );
        let team: Value =
            serde_json::from_str(result["result"]["value"].as_str().unwrap_or("null"))
                .map_err(|_| anyhow::anyhow!("cannot read Slack workspace session"))?;
        if team.is_object() && team["domain"] == workspace {
            found = Some(team);
            chosen_target_session = Some(session_id.to_owned());
            break;
        }
    }
    let team = found.context("chosen workspace not found; sign in and open it in Chrome first")?;
    let cookies = cdp!(
        "Network.getCookies",
        json!({"urls":["https://app.slack.com/",format!("https://{workspace}.slack.com/")]}),
        chosen_target_session.as_deref()
    );
    let cookie = cookies["cookies"]
        .as_array()
        .and_then(|cookies| {
            cookies.iter().find(|c| {
                c["name"] == "d"
                    && c["domain"]
                        .as_str()
                        .is_some_and(|d| d == ".slack.com" || d == "slack.com")
            })
        })
        .and_then(|c| c["value"].as_str())
        .context("Slack session cookie missing")?;
    let decoded =
        url::form_urlencoded::parse(format!("d={}", cookie.replace('+', "%2B")).as_bytes())
            .next()
            .context("invalid Slack session cookie")?
            .1
            .into_owned();
    let captured = Session {
        token: team["token"]
            .as_str()
            .context("Slack web token missing")?
            .to_owned(),
        cookie: decoded,
        domain: workspace.to_owned(),
        team_id: team["teamId"].as_str().map(str::to_owned),
    };
    let verified: Value = client
        .post(format!("https://{workspace}.slack.com/api/auth.test"))
        .header("Cookie", cookie_header(&captured.cookie))
        .header("Origin", "https://app.slack.com")
        .form(&[("token", captured.token.as_str())])
        .send()
        .await
        .map_err(|_| anyhow::anyhow!("Slack session verification failed"))?
        .json()
        .await
        .map_err(|_| anyhow::anyhow!("invalid Slack verification response"))?;
    if verified["ok"] != true || verified["team_id"].as_str() != captured.team_id.as_deref() {
        bail!("Slack session verification rejected; no credentials saved");
    }
    let parent = output
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .context("output must have a private parent directory")?;
    let metadata =
        fs::symlink_metadata(parent).context("create the private output directory first")?;
    if !metadata.is_dir()
        || metadata.permissions().mode() & 0o077 != 0
        || metadata.uid() != unsafe { libc::geteuid() }
    {
        bail!("output directory must be owned and private (0700)");
    }
    let temporary = parent.join(format!(".slack-session-{}.tmp", std::process::id()));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temporary)?;
    let saved = (|| -> Result<()> {
        file.write_all(&serde_json::to_vec(&captured)?)?;
        file.sync_all()?;
        fs::rename(&temporary, output)?;
        Ok(())
    })();
    if saved.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    saved.context("could not save private session file")?;
    tracing::info!("verified Slack session saved; close the CDP browser before normal use");
    Ok(())
}
