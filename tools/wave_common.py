"""Small deployment state and persistence helpers shared by Wave tools."""

from __future__ import annotations

import json
import os
import re
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

PROFILE_PATH = "/nix/var/nix/profiles/system"
CURRENT_SYSTEM_PATH = "/run/current-system"
CONFIRM_TIMEOUT = 150
ACTIVATION_TIMEOUT = 300
HEALTH_WINDOW = 120
ROLLBACK_HEALTH_WINDOW = 60
HEALTH_INTERVAL = 5
HEALTH_STREAK = 3
DEPLOY_RS_REV = "e760371d631165e7d8de5b0dcf148e21ec4c16f0"

_MAX_LOG_BYTES = 2 * 1024 * 1024


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def atomic_json(path: Path, payload: dict) -> None:
    """Write private (0600) JSON atomically in the destination directory."""
    path = Path(path)
    parent = path.parent
    if not parent.is_dir():
        raise FileNotFoundError(str(parent))
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=parent)
    temporary_path = Path(temporary)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            json.dump(payload, output, separators=(",", ":"), sort_keys=True)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary_path, path)
    except BaseException:
        try:
            temporary_path.unlink()
        except FileNotFoundError:
            pass
        raise


def load_json(path: Path) -> dict:
    with Path(path).open(encoding="utf-8") as source:
        value = json.load(source)
    if not isinstance(value, dict):
        raise ValueError("JSON value must be an object")
    return value


def _realpath(path: str) -> str | None:
    try:
        return os.path.realpath(path, strict=True)
    except (OSError, ValueError):
        return None


def snapshot_system() -> dict:
    try:
        profile_link = os.readlink(PROFILE_PATH)
    except (OSError, ValueError):
        profile_link = None
    return {
        "profile_link": profile_link,
        "profile_closure": _realpath(PROFILE_PATH),
        "current_system": _realpath(CURRENT_SYSTEM_PATH),
    }


def same_system(actual: dict, expected: dict) -> bool:
    keys = ("profile_link", "profile_closure", "current_system")
    return all(
        actual.get(key) is not None
        and expected.get(key) is not None
        and actual.get(key) == expected.get(key)
        for key in keys
    )


def canary_path(context: dict) -> Path:
    closure = str(context["new_profile_closure"])
    name = Path(closure).name
    prefix = name.split("-", 1)[0]
    if not closure.startswith("/nix/store/") or not re.fullmatch(r"[a-z0-9]{32}", prefix):
        raise ValueError("invalid new profile closure")
    return Path(context["temp_path"]) / f"deploy-rs-canary-{prefix}"


def _native_pid(run_dir: Path) -> int:
    with (Path(run_dir) / "native.pid").open("rb") as source:
        data = source.read(65)
    if len(data) > 64:
        raise ValueError("native PID is too large")
    text = data.decode("ascii").strip()
    if not re.fullmatch(r"[0-9]+", text):
        raise ValueError("malformed native PID")
    return int(text)


def _native_process_info(run_dir: Path) -> tuple[str, str]:
    try:
        pid = _native_pid(Path(run_dir))
    except FileNotFoundError:
        return "absent", ""
    except (OSError, UnicodeError, ValueError):
        return "unknown", ""
    if pid <= 1:
        return "unknown", ""
    try:
        result = subprocess.run(
            ["/bin/ps", "-ww", "-p", str(pid), "-o", "stat=", "-o", "command="],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=2,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return "unknown", ""
    output = result.stdout.strip()
    if result.returncode == 1 and not output:
        return "exited", ""
    if result.returncode != 0 or not output:
        return "unknown", ""
    status, separator, command = output.partition(" ")
    if not separator or not status or not command:
        return "unknown", ""
    if "Z" in status:
        return "exited", command
    return "running", command


def process_state(run_dir: Path) -> str:
    state, _ = _native_process_info(run_dir)
    return state


def native_process_matches(context: dict) -> bool:
    run_dir = Path(context["run_dir"])
    state, command = _native_process_info(run_dir)
    if state != "running":
        return False
    return (
        str(context["new_profile_closure"]) in command
        and str(context["temp_path"]) in command
        and " activate " in command
    )


def activation_result(run_dir: Path) -> str:
    try:
        logs = [p for p in Path(run_dir).glob("activate_activate_*.log") if p.is_file()]
    except OSError:
        return "unknown"
    if not logs:
        return "not_started"
    if len(logs) != 1:
        return "unknown"
    try:
        with logs[0].open("rb") as source:
            data = source.read(_MAX_LOG_BYTES + 1)
        if len(data) > _MAX_LOG_BYTES:
            return "unknown"
        text = data.decode("utf-8")
    except (OSError, UnicodeError):
        return "unknown"
    rollback_marker = "Attempting to re-activate the last generation"
    rollback_failure = any(
        "Nix reactivate last generation" in line
        and ("bad exit" in line or "Failed to run" in line)
        for line in text.splitlines()
    )
    if "There was an error de-activating" in text or rollback_failure:
        return "rollback_failed"
    rollback_text = text[text.rfind(rollback_marker) :] if rollback_marker in text else ""
    if rollback_marker in text and "ERROR [activate]" in rollback_text:
        return "rolled_back"
    if "Activation succeeded!" in text and "Got canary removal event, sending on channel" in text:
        return "confirmed"
    return "pending"


def append_event(run_dir: Path, event: str, **fields) -> None:
    if "timestamp" in fields or "event" in fields:
        raise ValueError("event fields cannot override reserved keys")
    record = {"timestamp": utc_now(), "event": event, **fields}
    encoded = (json.dumps(record, separators=(",", ":"), sort_keys=True) + "\n").encode()
    path = Path(run_dir) / "events.jsonl"
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        written = os.write(fd, encoded)
        if written != len(encoded):
            raise OSError("short event write")
    finally:
        os.close(fd)
