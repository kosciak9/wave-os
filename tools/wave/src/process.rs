use crate::presentation::{Completion, Progress};
use anyhow::{Result, anyhow};
use std::fs::OpenOptions;
use std::io::Read;
use std::os::fd::{AsRawFd, RawFd};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

const CAPTURE_LIMIT: usize = 8 * 1024 * 1024;
const PASSWORD_NOTICE: &[u8] = b"You will now be prompted for the sudo password";
static CANCELLED: OnceLock<Arc<AtomicBool>> = OnceLock::new();
static SIGNALS: OnceLock<bool> = OnceLock::new();

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProcessError {
    Signals,
    Start,
    OutputUnavailable,
    OutputSetup,
    OutputLimit,
    OutputRead,
    StopFence,
    Stop,
    Reap,
    Status,
}

impl std::fmt::Display for ProcessError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(match self {
            Self::Signals => "signal registration failed",
            Self::Start => "process start failed",
            Self::OutputUnavailable => "process output unavailable",
            Self::OutputSetup => "process output setup failed",
            Self::OutputLimit => "process output limit exceeded",
            Self::OutputRead => "process output read failed",
            Self::StopFence => "process stop fence failed",
            Self::Stop => "process stop failed",
            Self::Reap => "process reap failed",
            Self::Status => "process status unavailable",
        })
    }
}

impl std::error::Error for ProcessError {}

pub struct Output {
    pub code: i32,
    pub stdout: Vec<u8>,
    pub interrupted: bool,
    pub timed_out: bool,
}

pub fn cancelled() -> bool {
    CANCELLED
        .get()
        .is_some_and(|flag| flag.load(Ordering::SeqCst))
}

pub fn install_signals() -> Result<()> {
    let installed = SIGNALS.get_or_init(|| {
        let flag = CANCELLED.get_or_init(|| Arc::new(AtomicBool::new(false)));
        [
            signal_hook::consts::SIGINT,
            signal_hook::consts::SIGTERM,
            signal_hook::consts::SIGHUP,
        ]
        .into_iter()
        .all(|signal| signal_hook::flag::register(signal, Arc::clone(flag)).is_ok())
    });
    if !installed {
        return Err(anyhow!(ProcessError::Signals));
    }
    Ok(())
}

pub fn capture(command: &mut Command, timeout: Duration) -> Result<Output> {
    run_inner(command, timeout, true, false, true, None, || Ok(()))
}

/// Bounded read-only observation remains available while cancellation is latched.
pub fn capture_uncancelled(command: &mut Command, timeout: Duration) -> Result<Output> {
    run_inner(command, timeout, true, false, false, None, || Ok(()))
}

pub fn run(
    command: &mut Command,
    timeout: Duration,
    capture: bool,
    before_stop: impl FnMut() -> Result<()>,
    progress: &mut Progress,
    mut on_tick: impl FnMut(&mut Progress),
) -> Result<Output> {
    let result = run_inner(
        command,
        timeout,
        capture,
        true,
        true,
        Some(View {
            progress,
            on_tick: &mut on_tick,
        }),
        before_stop,
    );
    let completion = match &result {
        Ok(output) if output.interrupted => Completion::Interrupted,
        Ok(output) if output.timed_out => Completion::TimedOut,
        Ok(output) if output.code == 0 => Completion::Success,
        Ok(output) => Completion::Failed(output.code),
        Err(_) => Completion::Unavailable,
    };
    progress.finish(completion);
    result
}

struct View<'a> {
    progress: &'a mut Progress,
    on_tick: &'a mut dyn FnMut(&mut Progress),
}

struct Terminal {
    file: std::fs::File,
    attributes: libc::termios,
    prompted: bool,
    prompt_allowed: bool,
}

impl Terminal {
    fn save(prompt_allowed: bool) -> Option<Self> {
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .open("/dev/tty")
            .ok()?;
        let mut attributes = std::mem::MaybeUninit::uninit();
        // tcgetattr initializes termios only on success; the open file owns the fd.
        if unsafe { libc::tcgetattr(file.as_raw_fd(), attributes.as_mut_ptr()) } != 0 {
            return None;
        }
        Some(Self {
            file,
            attributes: unsafe { attributes.assume_init() },
            prompted: false,
            prompt_allowed,
        })
    }

    fn prompt(&mut self) {
        if self.prompted {
            return;
        }
        self.prompted = true;
        crate::presentation::password_prompt(&mut self.file);
    }
}

impl Drop for Terminal {
    fn drop(&mut self) {
        if unsafe { libc::tcsetattr(self.file.as_raw_fd(), libc::TCSANOW, &self.attributes) } != 0 {
            eprintln!("wave: terminal attributes could not be restored");
        }
    }
}

fn nonblocking(fd: RawFd) -> Result<()> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags == -1 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } == -1 {
        return Err(anyhow!(ProcessError::OutputSetup));
    }
    Ok(())
}

struct Drain {
    notice_tail: Vec<u8>,
    noticed: bool,
}

impl Drain {
    fn read(
        &mut self,
        pipe: &mut impl Read,
        output: &mut Vec<u8>,
        keep: bool,
        terminal: &mut Option<Terminal>,
        mut progress: Option<&mut Progress>,
        stderr: bool,
    ) -> Result<()> {
        let mut buffer = [0; 16384];
        // A continuously writing child must not starve deadline/cancellation checks.
        for _ in 0..16 {
            match pipe.read(&mut buffer) {
                Ok(0) => break,
                Ok(count) => {
                    if keep {
                        if output.len().saturating_add(count) > CAPTURE_LIMIT {
                            return Err(anyhow!(ProcessError::OutputLimit));
                        }
                        output.extend_from_slice(&buffer[..count]);
                    }
                    if !keep && let Some(progress) = &mut progress {
                        progress.feed(&buffer[..count], stderr);
                    }
                    if !self.noticed
                        && terminal
                            .as_ref()
                            .is_some_and(|terminal| terminal.prompt_allowed)
                    {
                        self.notice_tail.extend_from_slice(&buffer[..count]);
                        if self
                            .notice_tail
                            .windows(PASSWORD_NOTICE.len())
                            .any(|s| s == PASSWORD_NOTICE)
                        {
                            self.noticed = true;
                            if let Some(terminal) = terminal {
                                terminal.prompt();
                            }
                        }
                        let retain = PASSWORD_NOTICE.len() - 1;
                        if self.notice_tail.len() > retain {
                            self.notice_tail.drain(..self.notice_tail.len() - retain);
                        }
                    }
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(_) => return Err(anyhow!(ProcessError::OutputRead)),
            }
        }
        Ok(())
    }
}

fn run_inner(
    command: &mut Command,
    timeout: Duration,
    capture: bool,
    interactive: bool,
    honor_cancellation: bool,
    mut view: Option<View<'_>>,
    mut before_stop: impl FnMut() -> Result<()>,
) -> Result<Output> {
    let started = Instant::now();
    if honor_cancellation && cancelled() {
        before_stop().map_err(|_| anyhow!(ProcessError::StopFence))?;
        return Ok(Output {
            code: 130,
            stdout: Vec::new(),
            interrupted: true,
            timed_out: false,
        });
    }
    let mut terminal = if interactive {
        Terminal::save(view.as_ref().is_some_and(|view| view.progress.can_prompt()))
    } else {
        None
    };
    // Leave the caller's stdin configuration intact (Command defaults to inherit).
    command.stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = command.spawn().map_err(|_| anyhow!(ProcessError::Start))?;
    let mut stdout = child
        .stdout
        .take()
        .ok_or_else(|| anyhow!(ProcessError::OutputUnavailable))?;
    let mut stderr = child
        .stderr
        .take()
        .ok_or_else(|| anyhow!(ProcessError::OutputUnavailable))?;
    let mut bytes = Vec::new();
    let mut out = Drain {
        notice_tail: Vec::new(),
        noticed: false,
    };
    let mut err = Drain {
        notice_tail: Vec::new(),
        noticed: false,
    };
    let mut failure = nonblocking(stdout.as_raw_fd())
        .and_then(|_| nonblocking(stderr.as_raw_fd()))
        .err();
    loop {
        if let Some(view) = &mut view {
            (view.on_tick)(view.progress);
            view.progress.tick();
        }
        let interrupted = honor_cancellation && cancelled();
        let timed_out = started.elapsed() >= timeout;
        if interrupted || timed_out || failure.is_some() {
            // A failed fence must never be followed by termination. Dropping Child
            // leaves it alive so durable recovery can resolve ownership safely.
            before_stop().map_err(|_| anyhow!(ProcessError::StopFence))?;
            let status = if child.kill().is_ok() {
                child.wait().map_err(|_| anyhow!(ProcessError::Reap))?
            } else {
                // If kill lost a race with exit, reap that exit; never block on a
                // child that is still alive after a failed termination syscall.
                child
                    .try_wait()
                    .map_err(|_| anyhow!(ProcessError::Reap))?
                    .ok_or_else(|| anyhow!(ProcessError::Stop))?
            };
            if let Some(failure) = failure {
                return Err(failure);
            }
            return Ok(Output {
                code: status.code().unwrap_or(if interrupted { 130 } else { 124 }),
                stdout: bytes,
                interrupted,
                timed_out,
            });
        }
        if let Err(error) = out
            .read(
                &mut stdout,
                &mut bytes,
                capture,
                &mut terminal,
                view.as_mut().map(|view| &mut *view.progress),
                false,
            )
            .and_then(|_| {
                err.read(
                    &mut stderr,
                    &mut Vec::new(),
                    false,
                    &mut terminal,
                    view.as_mut().map(|view| &mut *view.progress),
                    true,
                )
            })
        {
            failure = Some(error);
            continue;
        }
        match child.try_wait() {
            Ok(Some(status)) => {
                // Never wait for pipe EOF: descendants may retain these fds.
                // Drain finite buffered output after the direct child is reaped.
                for _ in 0..33 {
                    let previous = bytes.len();
                    out.read(
                        &mut stdout,
                        &mut bytes,
                        capture,
                        &mut terminal,
                        view.as_mut().map(|view| &mut *view.progress),
                        false,
                    )?;
                    err.read(
                        &mut stderr,
                        &mut Vec::new(),
                        false,
                        &mut terminal,
                        view.as_mut().map(|view| &mut *view.progress),
                        true,
                    )?;
                    if bytes.len() == previous {
                        break;
                    }
                }
                return Ok(Output {
                    code: status.code().unwrap_or(1),
                    stdout: bytes,
                    interrupted: false,
                    timed_out: false,
                });
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(10)),
            Err(_) => failure = Some(anyhow!(ProcessError::Status)),
        }
    }
}
