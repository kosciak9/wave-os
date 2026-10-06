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

fn color(is_terminal: bool) -> bool {
    is_terminal
        && std::env::var_os("NO_COLOR").is_none()
        && std::env::var_os("TERM").is_none_or(|term| term != "dumb")
}

fn paint(text: &str, style: Style, color: bool) -> String {
    if !color {
        return text.to_owned();
    }
    let code = match style {
        Style::Heading => "1;36",
        Style::Detail => "2",
        Style::Success => "1;32",
        Style::Warning => "1;33",
        Style::Error => "1;31",
    };
    format!("\x1b[{code}m{text}\x1b[0m")
}

fn write(text: &str, style: Style) {
    if !ENABLED.load(Ordering::Relaxed) {
        return;
    }
    let stderr = std::io::stderr();
    let color = color(stderr.is_terminal());
    let _ = writeln!(stderr.lock(), "{}", paint(text, style, color));
}

/// Prints health probes as a table on stdout, followed by a bold verdict.
pub fn health_table<'a>(checks: impl IntoIterator<Item = (&'a str, bool)>, ok: bool) {
    let stdout = std::io::stdout();
    let color = color(stdout.is_terminal());
    let rows: Vec<_> = checks.into_iter().collect();
    let name_width = rows
        .iter()
        .map(|(name, _)| name.chars().count())
        .chain([5])
        .max()
        .unwrap_or(5);
    let status_width = "✗ unhealthy".chars().count();
    let rule = |left: &str, middle: &str, right: &str| {
        format!(
            "  {left}{}{middle}{}{right}",
            "─".repeat(name_width + 2),
            "─".repeat(status_width + 2)
        )
    };
    let mut output = stdout.lock();
    let _ = writeln!(output);
    let _ = writeln!(
        output,
        "{}",
        paint(&rule("┌", "┬", "┐"), Style::Detail, color)
    );
    let bar = paint("│", Style::Detail, color);
    let _ = writeln!(
        output,
        "  {bar} {} {bar} {} {bar}",
        paint(&format!("{:name_width$}", "Check"), Style::Heading, color),
        paint(
            &format!("{:status_width$}", "Status"),
            Style::Heading,
            color
        ),
    );
    let _ = writeln!(
        output,
        "{}",
        paint(&rule("├", "┼", "┤"), Style::Detail, color)
    );
    for (name, healthy) in rows {
        let status = if healthy {
            paint(
                &format!("{:status_width$}", "✓ healthy"),
                Style::Success,
                color,
            )
        } else {
            paint(
                &format!("{:status_width$}", "✗ unhealthy"),
                Style::Error,
                color,
            )
        };
        let _ = writeln!(output, "  {bar} {name:name_width$} {bar} {status} {bar}");
    }
    let _ = writeln!(
        output,
        "{}",
        paint(&rule("└", "┴", "┘"), Style::Detail, color)
    );
    let _ = writeln!(output);
    let verdict = if ok {
        paint("✓ Host healthy", Style::Success, color)
    } else {
        paint("✗ Host unhealthy", Style::Error, color)
    };
    let _ = writeln!(output, "{verdict}");
}

pub fn heading(text: &str) {
    write(&format!("\nwave-os {text}"), Style::Heading);
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
