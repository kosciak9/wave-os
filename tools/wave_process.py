"""Local direct-argv process execution for wave_switch."""
from __future__ import annotations

import os
import subprocess
import termios
import time
from contextlib import ExitStack, contextmanager
from dataclasses import dataclass
from pathlib import Path
from tempfile import TemporaryFile
from typing import Callable, Iterator


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: str = ""
    interrupted: bool = False
    timed_out: bool = False


_MAX_STDOUT = 8 * 1024 * 1024


def _open_log(path: Path):
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags, 0o600)
    try:
        os.fchmod(fd, 0o600)
        return os.fdopen(fd, "wb", buffering=0)
    except BaseException:
        os.close(fd)
        raise


@contextmanager
def _preserve_tty() -> Iterator[None]:
    fd = attrs = None
    try:
        fd = os.open("/dev/tty", os.O_RDWR | getattr(os, "O_NOCTTY", 0))
        attrs = termios.tcgetattr(fd)
    except (OSError, termios.error):
        if fd is not None:
            os.close(fd)
        yield
        return
    try:
        yield
    finally:
        try:
            termios.tcsetattr(fd, termios.TCSANOW, attrs)
        finally:
            os.close(fd)


def _stop(process: subprocess.Popen) -> None:
    """Terminate and reap only the Popen child, with bounded waits."""
    if process.poll() is not None:
        return
    try:
        process.terminate()
    except OSError:
        pass
    try:
        process.wait(timeout=2)
        return
    except (OSError, subprocess.TimeoutExpired):
        pass
    try:
        process.kill()
    except OSError:
        pass
    process.wait(timeout=2)


def run_logged(
    argv: list[str], *, cwd: Path, log_path: Path,
    cancelled: Callable[[], bool], before_stop: Callable[[], None],
    on_tick: Callable[[], None] | None = None, timeout: float = 1200,
    capture_stdout: bool = False, env: dict[str, str] | None = None,
) -> CommandResult:
    if cancelled():
        before_stop()
        return CommandResult(130, interrupted=True)

    process: subprocess.Popen | None = None
    stopping = False

    def stop_child() -> None:
        nonlocal stopping
        if stopping:
            return
        stopping = True
        marker_error: BaseException | None = None
        try:
            before_stop()
        except BaseException as exc:
            marker_error = exc
        try:
            if process is not None:
                _stop(process)
        finally:
            if marker_error is not None:
                raise marker_error

    try:
        with _preserve_tty(), ExitStack() as resources:
            log = resources.enter_context(_open_log(log_path))
            stdout_file = (
                resources.enter_context(TemporaryFile(mode="w+b"))
                if capture_stdout else None
            )
            process = subprocess.Popen(
                argv,
                cwd=cwd,
                stdin=None,
                stdout=stdout_file if stdout_file is not None else log,
                stderr=log,
                env=env,
            )
            if cancelled():
                stop_child()
                return CommandResult(130, interrupted=True)

            started = time.monotonic()
            interrupted = timed_out = False
            while process.poll() is None:
                time.sleep(0.1)
                if cancelled():
                    interrupted = True
                    stop_child()
                    break
                if time.monotonic() - started >= timeout:
                    timed_out = True
                    stop_child()
                    break
                if on_tick is not None:
                    try:
                        on_tick()
                    except BaseException:
                        stop_child()
                        raise

            process.wait(timeout=2)
            output = ""
            if stdout_file is not None:
                stdout_file.seek(0)
                data = stdout_file.read(_MAX_STDOUT + 1)
                if len(data) > _MAX_STDOUT:
                    raise OSError("captured stdout exceeds 8 MiB")
                log.seek(0, os.SEEK_END)
                log.write(data)
                output = data.decode("utf-8", "replace")
            if interrupted:
                return CommandResult(130, output, interrupted=True)
            if timed_out:
                return CommandResult(124, output, timed_out=True)
            code = process.returncode
            return CommandResult(code if code is not None else 0, output)
    except BaseException:
        if process is not None and not stopping and process.poll() is None:
            stop_child()
        raise
