"""Fail-closed local health authorization for the native deploy canary."""
from __future__ import annotations

import os
import json
import re
import signal
import sys
import time
from pathlib import Path

import wave_common as common
import wave_health as health

MAX_METADATA = 4096
MAX_CONTEXT = 65536
CANARY_RE = re.compile(r"deploy-rs-canary-[a-z0-9]{32}\Z")
_cancel = False
_run: Path | None = None


def _inside(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def _private_regular(path: Path, limit: int) -> None:
    if path.is_symlink() or not path.is_file():
        raise ValueError("unsafe metadata")
    stat = path.stat()
    if stat.st_uid != os.geteuid() or stat.st_mode & 0o077 or stat.st_size > limit:
        raise ValueError("unsafe metadata")


def _text(path: Path, limit: int) -> str:
    _private_regular(path, limit)
    return path.read_text(encoding="utf-8").strip()


def _canonical_dir(value: str, prefix: Path) -> Path:
    path = Path(value)
    if not path.is_absolute() or path.is_symlink() or not path.is_dir():
        raise ValueError("invalid run directory")
    if path.resolve() != path or path.stat().st_uid != os.geteuid() or path.stat().st_mode & 0o077:
        raise ValueError("invalid run directory")
    if not _inside(path, prefix):
        raise ValueError("run directory outside log prefix")
    return path


def _context(canary: Path, expected_wrapper: str, expected_system: str, log_prefix: str) -> tuple[dict, Path]:
    if os.geteuid() == 0:
        raise ValueError("confirmation must be unprivileged")
    if canary.is_symlink() or not canary.is_file() or canary.resolve() != canary:
        raise ValueError("invalid canary")
    temp = canary.parent
    wave_dir = temp.parent
    private_tmp = wave_dir.parent
    if temp.name != "canary" or not wave_dir.name.startswith("wave-") or private_tmp != Path("/private/tmp"):
        raise ValueError("invalid canary location")
    if not CANARY_RE.fullmatch(canary.name):
        raise ValueError("invalid canary name")
    canary_stat = canary.stat()
    if canary_stat.st_uid != 0 or canary_stat.st_mode & 0o022:
        raise ValueError("invalid canary ownership")
    if private_tmp.is_symlink() or not private_tmp.is_dir() or private_tmp.resolve() != private_tmp:
        raise ValueError("invalid temporary directory")
    for directory in (wave_dir, temp):
        if (directory.is_symlink() or not directory.is_dir() or directory.resolve() != directory
                or directory.stat().st_uid != os.geteuid() or directory.stat().st_mode & 0o077):
            raise ValueError("invalid temporary directory")
    prefix = Path(log_prefix)
    if not prefix.is_absolute() or prefix.is_symlink() or not prefix.is_dir() or prefix.resolve() != prefix:
        raise ValueError("invalid log prefix")
    if prefix.stat().st_uid != os.geteuid() or prefix.stat().st_mode & 0o077:
        raise ValueError("invalid log prefix ownership")
    run = _canonical_dir(Path(_text(canary.parent / "wave-log-dir", MAX_METADATA)).as_posix(), prefix)
    old_profile = _text(temp / "wave-old-profile", MAX_METADATA)
    context_path = run / "context.json"
    raw = _text(context_path, MAX_CONTEXT)
    context = json.loads(raw)
    if not isinstance(context, dict):
        raise ValueError("invalid context")
    for key in ("run_dir", "temp_path", "new_profile_closure", "new_system"):
        if not isinstance(context.get(key), str):
            raise ValueError("incomplete context")
    if context["run_dir"] != str(run) or context["temp_path"] != str(temp):
        raise ValueError("context path mismatch")
    if context["new_profile_closure"] != expected_wrapper or context["new_system"] != expected_system:
        raise ValueError("context identity mismatch")
    if not isinstance(context.get("old"), dict) or context["old"].get("profile_closure") != old_profile:
        raise ValueError("old profile mapping mismatch")
    if common.canary_path(context) != canary:
        raise ValueError("context canary mismatch")
    return context, run


def _cancelled() -> bool:
    return _cancel or (_run is not None and (_run / "cancelled").exists())


def _signal(_signum: int, _frame: object) -> None:
    global _cancel
    _cancel = True
    if _run is not None:
        try:
            fd = os.open(_run / "cancelled", os.O_WRONLY | os.O_CREAT, 0o600)
            os.close(fd)
        except OSError:
            pass


def _deny(run: Path, reason: str, result: dict) -> int:
    try:
        common.atomic_json(run / "confirmation-denied.json", {"reason": reason, "health": result})
        common.append_event(run, "confirmation_denied", reason=reason, health=result)
    except FileExistsError:
        pass
    return 130 if _cancel else 80


def _eligible(ctx: dict, canary: Path, wrapper: str, system: str, deadline: float) -> bool:
    if _cancelled() or (Path(ctx["run_dir"]) / "confirmation-denied.json").exists():
        return False
    if canary.is_symlink() or not canary.is_file() or canary.resolve() != canary:
        return False
    canary_stat = canary.stat()
    if canary_stat.st_uid != 0 or canary_stat.st_mode & 0o022:
        return False
    stamp = canary_stat.st_mtime
    now = time.time()
    if stamp > now or stamp + common.CONFIRM_TIMEOUT - now <= 10:
        return False
    actual = common.snapshot_system()
    if actual.get("profile_closure") != wrapper or actual.get("current_system") != system:
        return False
    if not common.native_process_matches(ctx):
        return False
    return time.time() < deadline


def _authorize(ctx: dict, run: Path, canary: Path, wrapper: str, system: str, root_stdio: str) -> int:
    if any((run / name).exists() for name in ("health-approved.json", "confirmation-denied.json")):
        return 80
    deadline = canary.stat().st_mtime + common.CONFIRM_TIMEOUT - 10
    if not _eligible(ctx, canary, wrapper, system, deadline):
        return _deny(run, "confirmation eligibility failed", {})
    try:
        fd = os.open(run / "health-started", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(fd)
    except FileExistsError:
        return 80
    invalid = False

    def cancelled() -> bool:
        return invalid or _cancelled() or time.time() >= deadline or not canary.exists()

    def sample(item: dict, attempt: int, streak: int) -> None:
        nonlocal invalid
        if not _eligible(ctx, canary, wrapper, system, deadline):
            invalid = True
        common.atomic_json(run / "post-health.json", {"health": item, "attempt": attempt, "streak": streak})
        common.append_event(run, "health_sample", health=item, attempt=attempt, streak=streak)

    result = health.wait_for_health(
        window_seconds=min(common.HEALTH_WINDOW, max(0, deadline - time.time())),
        interval_seconds=common.HEALTH_INTERVAL,
        required_successes=common.HEALTH_STREAK,
        cancelled=cancelled,
        on_sample=sample,
    )
    if invalid or result.get("ok") is not True or not _eligible(ctx, canary, wrapper, system, deadline):
        return _deny(run, "health window failed", result)
    try:
        common.atomic_json(run / "health-approved.json", {"timestamp": common.utc_now(), "health": result})
        common.append_event(run, "health_approved", health=result)
    except OSError:
        return _deny(run, "approval could not be persisted", result)
    if _cancelled() or not _eligible(ctx, canary, wrapper, system, deadline):
        return _deny(run, "confirmation race", result)
    return os.execv("/usr/bin/sudo", ["sudo", "-S", "-p", "", "-u", "root", root_stdio, "rm", str(canary)])


def main(argv: list[str] | None = None) -> int:
    global _cancel, _run
    _cancel = False
    _run = None
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 5:
        return 2
    canary, wrapper, system, root_stdio, log_prefix = map(str, argv)
    run: Path | None = None
    old_handlers: dict[int, object] = {}
    try:
        for item in (wrapper, system):
            path = Path(item)
            if not item.startswith("/nix/store/") or path.is_symlink() or not path.exists() or path.resolve() != path:
                raise ValueError("invalid helper identity")
        helper = Path(root_stdio)
        if (not root_stdio.startswith("/nix/store/") or helper.is_symlink() or not helper.is_file()
                or helper.resolve() != helper or not os.access(helper, os.X_OK)):
            raise ValueError("invalid root helper")
        canary_path = Path(canary)
        ctx, run = _context(canary_path, wrapper, system, log_prefix)
        _run = run
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            old_handlers[sig] = signal.signal(sig, _signal)
        return _authorize(ctx, run, canary_path, wrapper, system, root_stdio)
    except Exception:
        if run is not None:
            print("wave confirmation failed", file=sys.stderr)
            return _deny(run, "confirmation failed", {})
        print("wave confirmation unavailable", file=sys.stderr)
        return 80
    finally:
        for sig, handler in old_handlers.items():
            signal.signal(sig, handler)


if __name__ == "__main__":
    raise SystemExit(main())
