use anyhow::{Context, Result};
use std::io::Read;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

pub struct Output {
    pub code: i32,
    pub stdout: Vec<u8>,
    pub timed_out: bool,
}

impl Output {
    pub fn success(&self) -> bool {
        self.code == 0 && !self.timed_out
    }
}

/// Runs a command with captured stdout, killing it at the deadline.
/// Stderr is left to the caller so diagnostics stay visible unless silenced.
pub fn capture(command: &mut Command, timeout: Duration) -> Result<Output> {
    let deadline = Instant::now() + timeout;
    let mut child = command
        .stdout(Stdio::piped())
        .spawn()
        .context("process start failed")?;
    let mut stdout = child.stdout.take().context("process output unavailable")?;
    let reader = std::thread::spawn(move || {
        let mut bytes = Vec::new();
        let _ = stdout.read_to_end(&mut bytes);
        bytes
    });
    loop {
        if let Some(status) = child.try_wait()? {
            // Never wait for pipe EOF: descendants may retain the pipe.
            let stdout = if reader.is_finished() {
                reader.join().unwrap_or_default()
            } else {
                std::thread::sleep(Duration::from_millis(50));
                if reader.is_finished() {
                    reader.join().unwrap_or_default()
                } else {
                    Vec::new()
                }
            };
            return Ok(Output {
                code: status.code().unwrap_or(1),
                stdout,
                timed_out: false,
            });
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let status = child.wait()?;
            return Ok(Output {
                code: status.code().unwrap_or(124),
                stdout: Vec::new(),
                timed_out: true,
            });
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}
