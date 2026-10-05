use crate::model::{Host, sha40};
use serde::Deserialize;
use std::{
    io::{IsTerminal, Write},
    sync::atomic::{AtomicBool, AtomicUsize, Ordering},
    time::{Duration, Instant},
};

static ENABLED: AtomicBool = AtomicBool::new(true);
static SECTION: AtomicUsize = AtomicUsize::new(0);

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

fn write(text: &str, style: Style) {
    if !ENABLED.load(Ordering::Relaxed) {
        return;
    }
    let stderr = std::io::stderr();
    let mut output = stderr.lock();
    if color(stderr.is_terminal()) {
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

pub fn password_prompt(output: &mut std::fs::File) {
    let text = "\n=== ACTION REQUIRED: deploy-rs sudo password ===\nEnter your local sudo password at the deploy-rs prompt (hidden).\nPress Enter to submit or Ctrl-C to cancel. Wave does not read the password.\n";
    if color(output.is_terminal()) {
        let _ = write!(output, "\x1b[1;33;7m{text}\x1b[0m");
    } else {
        let _ = write!(output, "{text}");
    }
    let _ = output.flush();
}

pub fn begin(host: Host, command: &'static str) {
    SECTION.store(0, Ordering::Relaxed);
    write(
        &format!("\nWave {command} · {}", host.name()),
        Style::Heading,
    );
}

#[derive(Clone, Copy)]
pub enum Step {
    Source = 1,
    Preflight,
    Validation,
    Preparation,
    Build,
    Activation,
    Verification,
}

pub fn section(step: Step) {
    let number = step as usize;
    if SECTION.fetch_max(number, Ordering::Relaxed) >= number {
        return;
    }
    let name = match step {
        Step::Source => "Source / latest main",
        Step::Preflight => "Health / preflight",
        Step::Validation => "Validation",
        Step::Preparation => "Preparation",
        Step::Build => "Build",
        Step::Activation => "Privilege / activation",
        Step::Verification => "Verification",
    };
    write(&format!("\n[{number}/7] {name}"), Style::Heading);
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

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Task {
    Fetch,
    Clone,
    StaticChecks,
    Evaluation,
    RuntimeLock,
    Metadata,
    Build,
    Deploy,
    NativeActivation,
    HealthAuthorization,
    NativeCompletion,
    Observe,
    RollbackHealth,
    RecoveryHealth,
}

impl Task {
    fn name(self) -> &'static str {
        match self {
            Self::Fetch => "Latest main fetch",
            Self::Clone => "Shallow source copy",
            Self::StaticChecks => "Formatting and static checks",
            Self::Evaluation => "Nix evaluation",
            Self::RuntimeLock => "Pinned runtime flake resolution",
            Self::Metadata => "Deployment metadata validation",
            Self::Build => "Targeted Nix build",
            Self::Deploy => "Deploy-rs deployment",
            Self::NativeActivation => "Native activation",
            Self::HealthAuthorization => "Health checks before confirmation",
            Self::NativeCompletion => "Native activation completion",
            Self::Observe => "Native outcome verification",
            Self::RollbackHealth => "Restored-system health verification",
            Self::RecoveryHealth => "Recovery health and stability verification",
        }
    }
}

#[derive(Default)]
struct Lines {
    pending: Vec<u8>,
    oversized: bool,
}

#[derive(Deserialize)]
struct Activity {
    action: String,
    #[serde(rename = "type")]
    kind: Option<u64>,
}

pub enum Completion {
    Success,
    Failed(i32),
    Interrupted,
    TimedOut,
    Unavailable,
}

pub struct Progress {
    task: Task,
    initial_task: Task,
    started: Instant,
    last_notice: Instant,
    last_output: Instant,
    lines: [Lines; 2],
    counts: [u64; 3],
    reported: [u64; 3],
}

impl Progress {
    pub fn new(task: Task) -> Self {
        let now = Instant::now();
        detail(&format!("Running {}", task.name()));
        Self {
            task,
            initial_task: task,
            started: now,
            last_notice: now,
            last_output: now,
            lines: Default::default(),
            counts: [0; 3],
            reported: [0; 3],
        }
    }

    pub fn can_prompt(&self) -> bool {
        matches!(
            self.task,
            Task::Deploy
                | Task::NativeActivation
                | Task::HealthAuthorization
                | Task::NativeCompletion
        )
    }

    pub fn phase(&mut self, task: Task) {
        if self.task != task {
            self.task = task;
            detail(task.name());
            self.last_notice = Instant::now();
        }
    }

    pub fn feed(&mut self, data: &[u8], stderr: bool) {
        self.last_output = Instant::now();
        let lines = &mut self.lines[usize::from(stderr)];
        for byte in data {
            if *byte == b'\n' || *byte == b'\r' {
                if !lines.oversized {
                    // Only activity types reach the UI; messages, fields and paths are discarded.
                    if let Some(json) = lines.pending.strip_prefix(b"@nix ")
                        && let Ok(activity) = serde_json::from_slice::<Activity>(json)
                        && activity.action == "start"
                    {
                        let index = match activity.kind {
                            Some(105) => Some(0), // actBuild
                            Some(100) => Some(1), // actCopyPath
                            Some(101) => Some(2), // actFileTransfer
                            _ => None,
                        };
                        if let Some(index) = index {
                            self.counts[index] = self.counts[index].saturating_add(1);
                        }
                    }
                }
                lines.pending.clear();
                lines.oversized = false;
            } else if !lines.oversized {
                if lines.pending.len() == 4096 {
                    lines.pending.clear();
                    lines.oversized = true;
                } else {
                    lines.pending.push(*byte);
                }
            }
        }
    }

    fn activity(&mut self) {
        if self.counts != self.reported {
            let nouns = [
                ("build", "builds"),
                ("path copy", "path copies"),
                ("transfer", "transfers"),
            ];
            let counts: [String; 3] = std::array::from_fn(|index| {
                let noun = if self.counts[index] == 1 {
                    nouns[index].0
                } else {
                    nouns[index].1
                };
                format!("{} {noun}", self.counts[index])
            });
            detail(&format!(
                "Observed starts: {} · {} · {}",
                counts[0], counts[1], counts[2]
            ));
            self.reported = self.counts;
            self.last_notice = Instant::now();
        }
    }

    pub fn tick(&mut self) {
        if self.counts != self.reported && self.last_notice.elapsed() >= Duration::from_secs(1) {
            self.activity();
        } else if self.last_notice.elapsed() >= Duration::from_secs(15) {
            detail(&format!(
                "{}: still running · operation elapsed {}s · {}s since last subprocess output",
                self.task.name(),
                self.started.elapsed().as_secs(),
                self.last_output.elapsed().as_secs()
            ));
            self.last_notice = Instant::now();
        }
    }

    pub fn finish(&mut self, completion: Completion) {
        self.activity();
        let elapsed = self.started.elapsed().as_secs_f64();
        let name = self.initial_task.name();
        match completion {
            Completion::Success => detail(&format!("{name} completed in {elapsed:.1}s")),
            Completion::Failed(code) => {
                error(&format!("{name} failed (exit {code}) after {elapsed:.1}s"))
            }
            Completion::Interrupted => warning(&format!("{name} interrupted after {elapsed:.1}s")),
            Completion::TimedOut => error(&format!("{name} timed out after {elapsed:.1}s")),
            Completion::Unavailable => error(&format!("{name} could not complete")),
        }
    }
}
