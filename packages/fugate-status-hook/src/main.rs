//! Reports a turn's final Fugate status line to Herdr as pane metadata.
//!
//! Codex parses a Stop hook's stdout as JSON, so this hook never writes to
//! stdout and always exits 0: a missing status line is not a hook failure.

use std::env;
use std::io::{self, Read, Write};
use std::os::unix::net::UnixStream;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{json, Map, Value};

const STATUSES: [&str; 4] = ["completed", "waiting", "blocked", "failed"];
const TOKEN_TTL_MS: u64 = 24 * 60 * 60 * 1000;
const SOCKET_TIMEOUT: Duration = Duration::from_secs(1);
const MAX_TOKEN_LENGTH: usize = 80;

struct StatusLine<'a> {
    status: &'a str,
    run_id: &'a str,
    until: Option<&'a str>,
}

fn main() {
    if let Err(error) = run() {
        let _ = writeln!(io::stderr(), "fugate-status-hook: {error}");
    }
}

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let (Ok(socket_path), Ok(pane_id)) = (env::var("HERDR_SOCKET_PATH"), env::var("HERDR_PANE_ID"))
    else {
        return Ok(());
    };
    if env::var("HERDR_ENV").as_deref() != Ok("1") || socket_path.is_empty() || pane_id.is_empty() {
        return Ok(());
    }

    let mut input = String::new();
    io::stdin().read_to_string(&mut input)?;
    let payload: Value = serde_json::from_str(&input)?;
    let Some(message) = payload
        .get("last_assistant_message")
        .and_then(Value::as_str)
    else {
        return Ok(());
    };
    let Some(tokens) = status_tokens(message) else {
        return Ok(());
    };
    report(&socket_path, &pane_id, tokens)
}

/// Parses `fugate: <status> run=<id>[ until=<datetime>]` from the last
/// non-empty line, ignoring surrounding backticks and whitespace.
fn parse_status_line(message: &str) -> Option<StatusLine<'_>> {
    let line = message
        .split(is_line_break)
        .rev()
        .map(|line| line.trim().trim_matches('`').trim())
        .find(|line| !line.is_empty())?;
    let rest = line.strip_prefix("fugate:")?;
    if !rest.starts_with(char::is_whitespace) {
        return None;
    }
    let mut fields = rest.split_whitespace();
    let status = fields.next().filter(|status| STATUSES.contains(status))?;
    let run_id = fields
        .next()?
        .strip_prefix("run=")
        .filter(|id| !id.is_empty())?;
    let until = match fields.next() {
        None => None,
        Some(field) => Some(
            field
                .strip_prefix("until=")
                .filter(|until| !until.is_empty())?,
        ),
    };
    if fields.next().is_some() || (status == "waiting" && until.is_none()) {
        return None;
    }
    Some(StatusLine {
        status,
        run_id,
        until,
    })
}

fn is_line_break(character: char) -> bool {
    matches!(
        character,
        '\n' | '\r'
            | '\u{0b}'
            | '\u{0c}'
            | '\u{1c}'
            | '\u{1d}'
            | '\u{1e}'
            | '\u{85}'
            | '\u{2028}'
            | '\u{2029}'
    )
}

fn status_tokens(message: &str) -> Option<Map<String, Value>> {
    let line = parse_status_line(message)?;
    let reported_at = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .ok()?
        .as_millis()
        .to_string();
    let values = [
        Some(line.status),
        Some(line.run_id),
        line.until,
        Some(reported_at.as_str()),
    ];
    if values
        .iter()
        .flatten()
        .any(|value| value.chars().count() > MAX_TOKEN_LENGTH)
    {
        return None;
    }
    let mut tokens = Map::new();
    tokens.insert("fugate_status".into(), line.status.into());
    tokens.insert("fugate_run".into(), line.run_id.into());
    tokens.insert(
        "fugate_until".into(),
        line.until.map_or(Value::Null, Value::from),
    );
    tokens.insert("fugate_at".into(), reported_at.into());
    Some(tokens)
}

fn report(
    socket_path: &str,
    pane_id: &str,
    tokens: Map<String, Value>,
) -> Result<(), Box<dyn std::error::Error>> {
    let request = json!({
        "id": format!("fugate:{pane_id}:{}", tokens["fugate_at"].as_str().unwrap_or_default()),
        "method": "pane.report_metadata",
        "params": {
            "pane_id": pane_id,
            "source": "user:fugate",
            "ttl_ms": TOKEN_TTL_MS,
            "tokens": tokens,
        },
    });
    let mut stream = UnixStream::connect(socket_path)?;
    stream.set_read_timeout(Some(SOCKET_TIMEOUT))?;
    stream.set_write_timeout(Some(SOCKET_TIMEOUT))?;
    let mut line = serde_json::to_vec(&request)?;
    line.push(b'\n');
    stream.write_all(&line)?;
    // Herdr answers each request on the same connection; waiting for that
    // reply keeps the request from being cut off by an early close.
    let mut reply = [0; 65536];
    let _ = stream.read(&mut reply)?;
    Ok(())
}
