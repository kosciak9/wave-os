use crate::model::sha40;
use std::{
    io::{IsTerminal, Write},
    sync::atomic::{AtomicBool, Ordering},
};

static ENABLED: AtomicBool = AtomicBool::new(true);

pub fn enable(enabled: bool) {
    ENABLED.store(enabled, Ordering::Relaxed);
}

enum Style {
    Heading,
    Detail,
    Success,
    Warning,
    Error,
}

fn write(text: &str, style: Style) {
    if !ENABLED.load(Ordering::Relaxed) {
        return;
    }
    let stderr = std::io::stderr();
    let color = stderr.is_terminal()
        && std::env::var_os("NO_COLOR").is_none()
        && std::env::var_os("TERM").is_none_or(|term| term != "dumb");
    let mut output = stderr.lock();
    if color {
        let code = match style {
            Style::Heading => "1;36",
            Style::Detail => "2",
            Style::Success => "1;32",
            Style::Warning => "1;33",
            Style::Error => "1;31",
        };
        let _ = writeln!(output, "\x1b[{code}m{text}\x1b[0m");
    } else {
        let _ = writeln!(output, "{text}");
    }
}

pub fn heading(text: &str) {
    write(&format!("\nWave {text}"), Style::Heading);
}

pub fn section(text: &str) {
    write(&format!("\n· {text}"), Style::Heading);
}

pub fn detail(text: &str) {
    write(&format!("  {text}"), Style::Detail);
}

pub fn success(text: &str) {
    write(&format!("✓ {text}"), Style::Success);
}

pub fn warning(text: &str) {
    write(&format!("! {text}"), Style::Warning);
}

pub fn error(text: &str) {
    write(&format!("✗ {text}"), Style::Error);
}

pub fn revision(label: &'static str, value: &str) {
    if sha40(value) {
        detail(&format!("{label}: {}", &value[..8]));
    }
}
