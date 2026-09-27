#!/usr/bin/env python3
"""Guarded, foreground-only orchestration for the Renekton native deploy."""
from __future__ import annotations

import contextlib
import errno
import fcntl
import json
import os
import platform
import pwd
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path
from typing import Callable

import wave_common as common
import wave_health
import wave_monitor
import wave_process

ROOT = Path(__file__).resolve().parent.parent
STATE = Path.home() / ".local/state/wave"
LOGS = STATE / "logs/safe-switch"
HEX40 = re.compile(r"^[0-9a-f]{40}$")
SAFE_PATH = re.compile(r"^/[A-Za-z0-9._+/:=-]+$")

_cancel = False
_current_run: Path | None = None
_console_broken = False


def _git(repo: Path, args: list[str], *, allow_missing: bool = False) -> str:
    result = subprocess.run(["git", *args], cwd=repo, stdin=None, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True, timeout=30, check=False)
    if result.returncode:
        if allow_missing and result.returncode == 1:
            return ""
        raise RuntimeError(result.stderr.strip() or "git command failed")
    return result.stdout.strip()


def _commit(repo: Path) -> str:
    value = _git(repo, ["rev-parse", "HEAD"])
    if not HEX40.fullmatch(value):
        raise RuntimeError("HEAD is not a full commit")
    return value


def _clean_upstream(repo: Path, commit: str) -> None:
    if _git(repo, ["status", "--porcelain"]):
        raise RuntimeError("working tree is not clean (including untracked files)")
    # A detached HEAD is valid.  symbolic-ref status 1 means precisely that;
    # other failures are not silently converted into “no upstream”.
    branch_result = subprocess.run(["git", "symbolic-ref", "--quiet", "--short", "HEAD"], cwd=repo,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False)
    if branch_result.returncode == 1:
        return
    if branch_result.returncode:
        raise RuntimeError("cannot determine current branch")
    branch = branch_result.stdout.strip()
    upstream = _git(repo, ["for-each-ref", "--format=%(upstream)", f"refs/heads/{branch}"])
    if not upstream:
        return
    ref = subprocess.run(["git", "show-ref", "--verify", "--quiet", upstream], cwd=repo,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    if ref.returncode not in (0, 1):
        raise RuntimeError("cannot inspect configured upstream")
    if ref.returncode == 1:
        return
    if _git(repo, ["rev-parse", upstream]) != commit:
        raise RuntimeError("HEAD differs from configured local upstream")


def _cancelled() -> bool:
    return _cancel or (_current_run is not None and (_current_run / "cancelled").exists())


def _cancel_marker() -> None:
    if _current_run is None:
        return
    marker = _current_run / "cancelled"
    fd = os.open(marker, os.O_WRONLY | os.O_CREAT, 0o600)
    os.close(fd)


def _signal(_signum: int, _frame: object) -> None:
    global _cancel
    _cancel = True
    with contextlib.suppress(OSError):
        _cancel_marker()


def _stage(text: str) -> None:
    global _console_broken, _cancel
    if not text or _console_broken:
        return
    try:
        print(text, flush=True)
    except (BrokenPipeError, OSError):
        _console_broken = True
        _cancel = True
        with contextlib.suppress(OSError):
            _cancel_marker()


def _nix(repo: Path, args: list[str], run: Path, name: str, *, capture: bool = False,
         timeout: float = 1200) -> wave_process.CommandResult:
    argv = ["devenv", "--quiet", "shell", "--", *args]
    return wave_process.run_logged(argv, cwd=repo, log_path=run / name,
                                   cancelled=_cancelled, before_stop=_cancel_marker,
                                   on_tick=None, timeout=timeout,
                                   capture_stdout=capture)


def render_runtime_flake(repo: Path, commit: str, temp_path: Path, run_dir: Path) -> Path:
    """Create the isolated flake used by one committed source revision."""
    source = "git+file://" + Path(repo).as_uri().removeprefix("file://") + f"?rev={commit}"
    q = lambda value: json.dumps(str(value)).replace("${", "\\${")
    text = f'''{{
  inputs.source.url = {q(source)};
  outputs = {{ self, source }}: let
    node = source.deploy.nodes.renekton // {{ tempPath = {q(temp_path)}; }};
  in {{
    deploy = source.deploy // {{ nodes.renekton = node; }};
    packages.aarch64-darwin.profile = node.profiles.system.path;
    packages.aarch64-darwin.deploy-rs = source.inputs.deploy-rs.packages.aarch64-darwin.deploy-rs;
    packages.aarch64-darwin.sudo = source.packages.aarch64-darwin.wave-deploy-sudo;
    checks.aarch64-darwin = source.inputs.deploy-rs.lib.aarch64-darwin.deployChecks self.deploy;
    waveMeta = {{ hostname=node.hostname; ssh_user=node.sshUser; profile_user=node.profiles.system.user;
      profile_path=node.profiles.system.profilePath; profile_closure=toString node.profiles.system.path;
      system_closure=toString source.darwinConfigurations.renekton.system;
       deploy_package=toString self.packages.aarch64-darwin.deploy-rs;
       sudo_wrapper=node.sudo; expected_sudo=toString self.packages.aarch64-darwin.sudo;
       temp_path=node.tempPath; confirm_timeout=node.confirmTimeout; activation_timeout=node.activationTimeout;
       auto_rollback=node.autoRollback; magic_rollback=node.magicRollback; interactive_sudo=node.interactiveSudo;
       ssh_opts=node.sshOpts;
       source_revision=if source ? rev then source.rev else null;
       deploy_revision=if source.inputs.deploy-rs ? rev then source.inputs.deploy-rs.rev else null; }};
  }};
}}'''
    flake = run_dir / "flake"
    flake.mkdir(mode=0o700)
    (flake / "flake.nix").write_text(text, encoding="utf-8")
    (flake / "flake.nix").chmod(0o600)
    return flake


def _meta(repo: Path, flake: Path, run: Path, expected_temp: Path, commit: str) -> dict:
    result = _nix(repo, ["nix", "eval", "--json", "--no-write-lock-file", f"path:{flake}#waveMeta"], run, "runtime-meta.log", capture=True)
    if result.returncode or result.interrupted or result.timed_out:
        if result.interrupted or _cancel:
            raise InterruptedError("runtime metadata evaluation interrupted")
        raise ValueError("runtime metadata evaluation failed")
    try:
        value = json.loads(result.stdout)
    except (TypeError, ValueError) as exc:
        raise ValueError("runtime metadata was not JSON") from exc
    required = {"hostname", "ssh_user", "profile_user", "profile_path", "profile_closure", "system_closure", "deploy_package", "sudo_wrapper", "expected_sudo", "temp_path", "confirm_timeout", "activation_timeout", "auto_rollback", "magic_rollback", "interactive_sudo", "ssh_opts", "source_revision", "deploy_revision"}
    if not isinstance(value, dict) or set(value) != required:
        raise ValueError("runtime metadata schema mismatch")
    if value["hostname"] != "localhost" or value["profile_user"] != "root" or value["ssh_user"] != pwd.getpwuid(os.getuid()).pw_name:
        raise ValueError("runtime metadata target is not local root via the current user")
    if value["profile_path"] != common.PROFILE_PATH or value["temp_path"] != str(expected_temp):
        raise ValueError("runtime metadata path mismatch")
    if (value["confirm_timeout"], value["activation_timeout"]) != (common.CONFIRM_TIMEOUT, common.ACTIVATION_TIMEOUT) or value["auto_rollback"] is not True or value["magic_rollback"] is not True or value["interactive_sudo"] is not True:
        raise ValueError("runtime metadata protocol mismatch")
    expected_ssh_opts = ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectionAttempts=1", "-o", "ConnectTimeout=5"]
    if value["ssh_opts"] != expected_ssh_opts or value["source_revision"] != commit or value["deploy_revision"] != common.DEPLOY_RS_REV:
        raise ValueError("runtime metadata pin mismatch")
    if value["sudo_wrapper"] != value["expected_sudo"]:
        raise ValueError("runtime sudo adapter mismatch")
    for key in ("profile_closure", "system_closure", "deploy_package", "sudo_wrapper", "expected_sudo"):
        if not isinstance(value[key], str) or not SAFE_PATH.fullmatch(value[key]) or not value[key].startswith("/nix/store/"):
            raise ValueError("unsafe runtime store path")
    if value["source_revision"] is None:
        raise ValueError("production metadata has no source revision")
    return value


def _deployment_progress(run: Path) -> Callable[[], None]:
    last_streak = -1
    last_health_notice = 0.0
    stages: set[str] = set()

    def progress() -> None:
        nonlocal last_streak, last_health_notice
        if (run / "native.pid").is_file() and "pid" not in stages:
            stages.add("pid")
            _stage("Target is starting native activation")
        if (run / "health-started").is_file() and "started" not in stages:
            stages.add("started")
            _stage("Activation completed; checking health before confirmation")
        post_health = run / "post-health.json"
        if post_health.is_file():
            item = common.load_json(post_health)
            streak = item.get("streak")
            if not isinstance(streak, int):
                raise ValueError("malformed post-health progress")
            now = time.monotonic()
            if streak != last_streak or now - last_health_notice >= 15:
                health_item = item.get("health", {})
                checks = health_item.get("checks", {}) if isinstance(health_item, dict) else {}
                unhealthy = [name for name, check in checks.items()
                             if isinstance(check, dict) and check.get("ok") is False]
                suffix = f"; unhealthy: {', '.join(unhealthy)}" if unhealthy else ""
                _stage(f"Health verification streak {streak}/{common.HEALTH_STREAK}{suffix}")
                last_streak, last_health_notice = streak, now
        if (run / "health-approved.json").is_file() and "approved" not in stages:
            common.load_json(run / "health-approved.json")
            stages.add("approved")
            _stage("Health passed; deploy-rs confirmation in progress")

    return progress


def _deploy(repo: Path, run: Path, package: str) -> wave_process.CommandResult:
    executable = str(Path(package) / "bin/deploy")
    env = dict(os.environ)
    env["PATH"] = "/nix/var/nix/profiles/default/bin:/usr/bin:/bin:" + env.get("PATH", "")
    argv = [executable, "--no-progress",
            "--no-demarcate-output", "--log-dir", str(run), f"path:{run / 'flake'}#renekton.system",
            "--", "--no-write-lock-file"]
    return wave_process.run_logged(argv, cwd=repo, log_path=run / "console.log",
                                   cancelled=_cancelled, before_stop=_cancel_marker,
                                   on_tick=_deployment_progress(run), timeout=1200, env=env)


def _finish(run: Path, commit: str | None, result: str, health: dict, old: dict,
            new: dict, error: str | None = None, state: dict | None = None) -> int:
    payload = {"commit": commit, "result": result, "timestamp": common.utc_now(), "health": health,
               "log_dir": str(run), "old": old, "new": new, "state": state or {},
               "interrupted": _cancel, "error": error}
    try:
        common.atomic_json(run / "result.json", payload)
        common.atomic_json(STATE / "latest.json", payload)
    except OSError as exc:
        print(f"critical: cannot persist result; inspect logs at {run}: {exc}", file=sys.stderr)
        return 40
    _stage(f"{result}; logs: {run}")
    return {"success": 0, "preflight_failed": 10, "validation_failed": 20,
            "deploy_failed_rolled_back": 30, "deploy_failed_unchanged": 30,
            "critical": 40, "interrupted": 130}[result]


def _cleanup(temp_root: Path | None) -> None:
    if temp_root is None or temp_root.parent != Path("/private/tmp") or not temp_root.name.startswith("wave-"):
        return
    if temp_root.exists():
        shutil.rmtree(temp_root)


def _private_directory(path: Path, *, create: bool = True) -> None:
    if path.exists() and path.is_symlink():
        raise PermissionError(f"refusing symlinked state directory: {path}")
    if create:
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not path.is_dir() or path.resolve() != path or path.stat().st_uid != os.getuid() or path.stat().st_mode & 0o077:
        raise PermissionError(f"state directory is not private and canonical: {path}")


def _lock_path(path: Path) -> int:
    if path.exists() and path.is_symlink():
        raise PermissionError(f"refusing symlinked lock: {path}")
    return os.open(path, os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)


class RecoveredRollback(Exception):
    """A verified stale active marker was cleared; this invocation must stop."""


class RecoveredSuccessMarker(Exception):
    """A stale marker after verified successful activation was cleared."""


RUN_NAME = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{6}(?:\.\d+)?Z)-([0-9a-f]{40})-([A-Za-z0-9_-]+)$")
UNKNOWN_RUN_NAME = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{6}(?:\.\d+)?Z)-unknown-([A-Za-z0-9_-]+)$")


def _native_evidence(run: Path) -> bool:
    return (run / "native.pid").exists() or any(run.glob("activate_activate_*.log"))


def _run_dirs() -> tuple[list[Path], bool]:
    """Return a bounded, newest-first set of canonical private run directories."""
    root = LOGS.resolve(strict=True)
    items = []
    for path in LOGS.iterdir():
        try:
            if path.is_symlink():
                raise ValueError("symlinked run directory in private log root")
            if not path.is_dir() or path.resolve(strict=True).parent != root:
                continue
            match = RUN_NAME.fullmatch(path.name)
            unknown = UNKNOWN_RUN_NAME.fullmatch(path.name)
            if unknown is not None:
                if (path / "context.json").exists() or _native_evidence(path):
                    raise ValueError("unknown preflight run contains native evidence")
                stamp = unknown.group(1)
                datetime.strptime(stamp[:-1], "%Y-%m-%dT%H%M%S") if "." not in stamp else datetime.strptime(stamp[:-1], "%Y-%m-%dT%H%M%S.%f")
                continue
            if match is None:
                if ("-unknown-" in path.name or (path / "context.json").exists()
                        or _native_evidence(path)):
                    raise ValueError("activation run directory name is malformed")
                continue
            stamp = match.group(1)
            timestamp = (datetime.strptime(stamp[:-1], "%Y-%m-%dT%H%M%S") if "." not in stamp
                         else datetime.strptime(stamp[:-1], "%Y-%m-%dT%H%M%S.%f"))
            items.append((timestamp, path.name, path))
        except OSError as exc:
            raise ValueError("cannot safely inspect private activation run") from exc
    ordered = [path for _, _, path in sorted(items, reverse=True)]
    return ordered[:200], len(ordered) > 200


def _run_context(run: Path) -> dict:
    if run.parent != LOGS.resolve(strict=True) or run.is_symlink() or run.resolve(strict=True) != run:
        raise ValueError("noncanonical activation run")
    context = common.load_json(run / "context.json")
    match = RUN_NAME.fullmatch(run.name)
    old = context.get("old")
    new = context.get("new_profile_closure")
    new_system = context.get("new_system")
    if (match is None or context.get("run_dir") != str(run) or not isinstance(old, dict)
            or not isinstance(new, str) or not isinstance(new_system, str)):
        raise ValueError("activation context identity is invalid")
    if context.get("commit") not in (None, match.group(2)):
        raise ValueError("activation commit identity is invalid")
    if any(not isinstance(old.get(k), str) or not old[k].startswith("/") for k in ("profile_link", "profile_closure", "current_system")):
        raise ValueError("activation old snapshot is invalid")
    if not new.startswith("/nix/store/") or not new_system.startswith("/nix/store/"):
        raise ValueError("activation new snapshot is invalid")
    context["commit"] = match.group(2)
    return context


def _rollback_proof(run: Path, context: dict, *, persist: bool = False) -> dict | None:
    pid = common.process_state(run)
    native = common.activation_result(run)
    old = context["old"]
    if pid not in {"absent", "exited"} or native != "rolled_back":
        return None
    if not (run / "native.pid").is_file() or not common.same_system(common.snapshot_system(), old):
        return None
    health = wave_monitor._health_window(common.ROLLBACK_HEALTH_WINDOW, lambda _text: None)
    after = common.snapshot_system()
    if (health.get("ok") is not True or not isinstance(health.get("health"), dict)
            or health["health"].get("ok") is not True or not common.same_system(after, old)
            or common.process_state(run) not in {"absent", "exited"}
            or common.activation_result(run) != "rolled_back"):
        return None
    if persist:
        record = {**health, "latest_checks": health.get("health", {})}
        common.atomic_json(run / "rollback-health.json", record)
    return health


def _active_matches(active: dict, run: Path, context: dict) -> bool:
    return (active.get("run_dir") == str(run) and active.get("commit") == context["commit"]
            and active.get("old") == context["old"]
            and active.get("new", {}).get("profile_closure") == context["new_profile_closure"]
            and active.get("new", {}).get("current_system") == context["new_system"])


def _confirmed_health_approval(run: Path) -> bool:
    try:
        approval = common.load_json(run / "health-approved.json")
    except (OSError, ValueError, TypeError, UnicodeError):
        return False
    health = approval.get("health")
    return (isinstance(approval.get("timestamp"), str) and bool(approval["timestamp"])
            and isinstance(health, dict) and health.get("ok") is True
            and isinstance(health.get("health"), dict) and health["health"].get("ok") is True
            and isinstance(health["health"].get("checks"), dict))


def _approval_required(active: dict | None) -> str | None:
    """Resolve the latest meaningful native activation without trusting latest.json."""
    runs, truncated = _run_dirs()
    if active is not None:
        active_run = Path(active.get("run_dir", ""))
        if active_run not in runs:
            runs.insert(0, active_run)
            runs = runs[:200]
    for run in runs:
        result_path = run / "result.json"
        try:
            context = _run_context(run)
            native = common.activation_result(run)
            if native == "not_started":
                if not _native_evidence(run) and not result_path.exists():
                    continue
                pid = common.process_state(run)
                if pid not in {"absent", "exited"} or any(run.glob("activate_activate_*.log")):
                    raise ValueError("nonterminal native activation evidence is ambiguous")
                if not result_path.exists():
                    raise ValueError("native activation did not start but has no terminal result")
                unchanged = common.load_json(result_path)
                old = context["old"]
                actual = common.snapshot_system()
                if (unchanged.get("result") != "deploy_failed_unchanged"
                        or unchanged.get("commit") != context["commit"]
                        or unchanged.get("log_dir") != str(run)
                        or unchanged.get("old") != old
                        or unchanged.get("new", {}).get("profile_closure") != context["new_profile_closure"]
                        or unchanged.get("new", {}).get("current_system") != context["new_system"]
                        or not isinstance(unchanged.get("health"), dict)
                        or unchanged["health"].get("ok") is not True
                        or not isinstance(unchanged["health"].get("checks"), dict)
                        or not isinstance(unchanged.get("state"), dict)
                        or not common.same_system(unchanged["state"], old)
                        or not common.same_system(actual, old)):
                    raise ValueError("unchanged activation result conflicts with native/system evidence")
                if active is not None and _active_matches(active, run, context):
                    raise ValueError("active marker remains for an unchanged activation; manual review required")
                continue
            if native in {"not_started", "pending"} and not _native_evidence(run):
                continue
            if native in {"not_started", "pending"}:
                raise ValueError("native activation has no terminal outcome")
            if native not in {"rolled_back", "confirmed"}:
                raise ValueError("ambiguous native activation evidence")
            if not (run / "native.pid").is_file():
                raise ValueError("terminal native activation has no PID evidence")
            if common.process_state(run) not in {"absent", "exited"}:
                raise ValueError("native activation may still be running")
            actual = common.snapshot_system()
            old = context["old"]
            if native == "rolled_back":
                if not common.same_system(actual, old):
                    raise ValueError("rollback system does not match recorded old snapshot")
                if result_path.exists():
                    result = common.load_json(result_path)
                    if (result.get("result") != "deploy_failed_rolled_back"
                            or result.get("commit") != context["commit"] or result.get("log_dir") != str(run)
                            or result.get("old") != old
                            or result.get("new", {}).get("profile_closure") != context["new_profile_closure"]
                            or result.get("new", {}).get("current_system") != context["new_system"]
                            or not isinstance(result.get("health"), dict)
                            or result["health"].get("ok") is not True
                            or not isinstance(result["health"].get("checks"), dict)
                            or not isinstance(result.get("state"), dict)
                            or not common.same_system(result["state"], old)):
                        raise ValueError("rollback result conflicts with native evidence")
                    recovery_health = _rollback_proof(run, context)
                    if recovery_health is None:
                        raise ValueError("rollback health/state proof is incomplete")
                else:
                    if active is not None and not _active_matches(active, run, context):
                        raise ValueError("active marker does not identify recovered activation")
                    recovery_health = _rollback_proof(run, context, persist=True)
                    if recovery_health is None:
                        raise ValueError("rollback health/state proof is incomplete")
                    payload = {"commit": context["commit"],
                               "result": "deploy_failed_rolled_back", "timestamp": common.utc_now(),
                               "health": recovery_health.get("health", {}),
                               "log_dir": str(run), "old": old,
                               "new": {"profile_closure": context["new_profile_closure"], "current_system": context["new_system"]},
                               "state": actual, "interrupted": False, "error": "recovered native rollback"}
                    common.atomic_json(run / "result.json", payload)
                _reconcile_latest(run, result_path)
                if active is not None:
                    active_path = STATE / "active.json"
                    if not _active_matches(active, run, context):
                        raise ValueError("active marker does not identify recovered activation")
                    fresh = _rollback_proof(run, context)
                    if fresh is None or common.load_json(active_path) != active:
                        raise ValueError("active marker rollback recheck failed")
                    active_path.unlink()
                    raise RecoveredRollback()
                return context["commit"]
            if not result_path.exists():
                raise ValueError("native success has no persisted result")
            result = common.load_json(result_path)
            success_consistent = (result.get("result") == "success" and result.get("commit") == context["commit"]
                    and result.get("log_dir") == str(run)
                    and result.get("old") == context["old"]
                    and result.get("new", {}).get("profile_closure") == context["new_profile_closure"]
                    and result.get("new", {}).get("current_system") == context["new_system"]
                    and isinstance(result.get("health"), dict) and result["health"].get("ok") is True
                    and isinstance(result.get("state"), dict)
                    and common.same_system(result["state"], actual)
                    and actual.get("profile_closure") == context["new_profile_closure"]
                    and actual.get("current_system") == context["new_system"]
                    and _confirmed_health_approval(run))
            if success_consistent:
                if active is not None:
                    if not _active_matches(active, run, context) or not _confirmed_health_approval(run):
                        raise ValueError("stale active marker lacks matching confirmed activation proof")
                    fresh = wave_monitor._health_window(common.HEALTH_WINDOW, lambda _text: None)
                    after = common.snapshot_system()
                    if (fresh.get("ok") is not True or not isinstance(fresh.get("health"), dict)
                            or fresh["health"].get("ok") is not True
                            or not isinstance(fresh["health"].get("checks"), dict)
                            or not common.same_system(after, actual)
                            or common.process_state(run) not in {"absent", "exited"}
                            or common.activation_result(run) != "confirmed"
                            or common.load_json(STATE / "active.json") != active):
                        raise ValueError("stale active marker success recheck failed")
                    _reconcile_latest(run, result_path)
                    if (common.load_json(STATE / "active.json") != active
                            or not common.same_system(common.snapshot_system(), actual)
                            or common.process_state(run) not in {"absent", "exited"}
                            or common.activation_result(run) != "confirmed"):
                        raise ValueError("stale active marker changed before removal")
                    (STATE / "active.json").unlink()
                    raise RecoveredSuccessMarker()
                return None
            raise ValueError("native activation result conflicts with evidence")
        except FileNotFoundError:
            if _native_evidence(run):
                raise ValueError("native evidence has no readable activation context") from None
            continue
        except Exception:
            raise
    if truncated:
        raise ValueError("recent run scan reached its safety bound without a terminal activation")
    return None


def _run_order(path: Path, *, allow_unknown_preflight: bool = False) -> tuple[datetime, str]:
    if path.parent != LOGS.resolve(strict=True) or path.is_symlink() or path.resolve(strict=True) != path:
        raise ValueError("noncanonical result run")
    match = RUN_NAME.fullmatch(path.name)
    unknown = UNKNOWN_RUN_NAME.fullmatch(path.name) if allow_unknown_preflight else None
    if match is None and unknown is None:
        raise ValueError("result run name is malformed")
    if unknown is not None:
        if _native_evidence(path) or (path / "context.json").exists():
            raise ValueError("unknown run contains native evidence")
        stamp = unknown.group(1)
    else:
        stamp = match.group(1)
    timestamp = (datetime.strptime(stamp[:-1], "%Y-%m-%dT%H%M%S") if "." not in stamp
                 else datetime.strptime(stamp[:-1], "%Y-%m-%dT%H%M%S.%f"))
    return timestamp, path.name


def _reconcile_latest(run: Path, result_path: Path) -> None:
    latest_path = STATE / "latest.json"
    if not latest_path.exists():
        common.atomic_json(latest_path, common.load_json(result_path))
        return
    latest = common.load_json(latest_path)
    latest_run_text = latest.get("log_dir")
    if not isinstance(latest_run_text, str):
        raise ValueError("latest result identity is invalid")
    latest_run = Path(latest_run_text)
    latest_order = _run_order(latest_run, allow_unknown_preflight=True)
    if UNKNOWN_RUN_NAME.fullmatch(latest_run.name):
        if latest.get("result") not in {"preflight_failed", "interrupted"}:
            raise ValueError("unknown latest run is not a preflight-only result")
    current_order = _run_order(run)
    if latest_order < current_order:
        common.atomic_json(latest_path, common.load_json(result_path))


def _approve_rollback(commit: str) -> bool:
    try:
        with open("/dev/tty", "r+", encoding="utf-8") as tty:
            tty.write(f"Wersja {commit[:8]} została wcześniej wycofana. Czy zatwierdzasz nową próbę wdrożenia? Wpisz dokładnie TAK: ")
            tty.flush()
            return tty.readline().rstrip("\r\n") == "TAK"
    except (OSError, EOFError):
        return False


def _finalize(run: Path, active_owned: bool,
              outcome: wave_monitor.DeploymentOutcome, commit: str | None,
              old: dict, new: dict) -> tuple[int, bool]:
    code = _finish(run, commit, outcome.result, outcome.health, old, new, outcome.error, outcome.state)
    if outcome.terminal and outcome.result != "critical" and code == outcome.code:
        try:
            if active_owned:
                (STATE / "active.json").unlink(missing_ok=True)
            active_owned = False
        except OSError as exc:
            print(f"critical: cannot clear active marker; inspect {run}: {exc}", file=sys.stderr)
            _finish(run, commit, "critical", outcome.health, old, new, "active marker removal", outcome.state)
            code = 40
    return code, active_owned


def safe_switch(repo: Path | None = None) -> int:
    global _cancel, _current_run, _console_broken
    _cancel = False
    _current_run = None
    _console_broken = False
    if platform.system() != "Darwin" or platform.machine() != "arm64" or os.geteuid() == 0:
        print("safe-switch requires a local non-root Darwin arm64 user", file=sys.stderr); return 10
    repo = (repo or ROOT).resolve()
    try:
        _private_directory(STATE)
        _private_directory(STATE / "logs")
        _private_directory(LOGS)
    except OSError as exc:
        print(f"safe-switch state initialization failed: {exc}", file=sys.stderr)
        return 10
    try:
        lock_fd = _lock_path(STATE / "safe-switch.lock")
    except OSError as exc:
        print(f"safe-switch lock initialization failed: {exc}", file=sys.stderr)
        return 10
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as exc:
        os.close(lock_fd)
        if exc.errno in (errno.EACCES, errno.EAGAIN): print("safe-switch is already running; inspect active.json", file=sys.stderr)
        return 10
    old_handlers = {sig: signal.signal(sig, _signal) for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    run = temp_root = None; active_owned = False; launched = False; context: dict | None = None
    run_prefix = common.utc_now().replace(":", "")
    phase = "preflight"
    old: dict = {}; new: dict = {}; health: dict = {}; commit: str | None = None
    try:
        try:
            active = common.load_json(STATE / "active.json") if (STATE / "active.json").exists() else None
            if active is not None:
                active_run = Path(active.get("run_dir", ""))
                if active_run.parent != LOGS.resolve(strict=True) or active_run.is_symlink() or active_run.resolve(strict=True) != active_run:
                    raise ValueError("active marker identity is invalid")
            rollback_commit = _approval_required(active)
        except RecoveredRollback:
            print("Odzyskano dowód wycofania poprzedniej wersji. Sprawdź wdrożenie; ta próba została zatrzymana.", file=sys.stderr)
            return 30
        except RecoveredSuccessMarker:
            print("Potwierdzone wdrożenie zostało odzyskane; znacznik aktywnego wdrożenia usunięto. Ta próba została zatrzymana.", file=sys.stderr)
            return 0
        except Exception as exc:
            print("safe-switch recovery is blocked by ambiguous activation evidence; verify native state and the Nix profile/current-system links manually", file=sys.stderr)
            return 10
        if active is not None:
            print("safe-switch is blocked by an unresolved active deployment; verify native state before removing its marker", file=sys.stderr)
            return 10
        if rollback_commit is not None and not _approve_rollback(rollback_commit):
            print("Poprzednia wersja została wycofana. Nie rozpoczęto wdrożenia; uruchom ponownie i wpisz dokładnie TAK.", file=sys.stderr)
            return 30
        try:
            try:
                commit = _commit(repo)
            except Exception as exc:
                commit = None
                run = Path(tempfile.mkdtemp(prefix=f"{run_prefix}-unknown-", dir=LOGS)).resolve()
                run.chmod(0o700)
                _current_run = run
                raise ValueError("cannot resolve repository HEAD") from exc
            run = Path(tempfile.mkdtemp(prefix=f"{run_prefix}-{commit}-", dir=LOGS)).resolve()
            if run.parent != LOGS.resolve():
                raise PermissionError("run directory escaped private log root")
            run.chmod(0o700)
            _current_run = run
            _clean_upstream(repo, commit)
            old = common.snapshot_system()
            if any(old.get(key) is None for key in ("profile_link", "profile_closure", "current_system")):
                raise ValueError("system snapshot is incomplete")
            old_activate = Path(old["profile_closure"]) / "activate"
            old_deploy = Path(old["profile_closure"]) / "deploy-rs-activate"
            if not (old_activate.is_file() and os.access(old_activate, os.X_OK) and old_deploy.is_file() and os.access(old_deploy, os.X_OK)):
                raise ValueError("old profile lacks deploy-rs activation and rollback entries")
            system_config = Path(old["profile_closure"]) / "systemConfig"
            if not system_config.is_file():
                raise ValueError("old profile lacks its native systemConfig evidence")
            try:
                configured_system = system_config.read_text(encoding="utf-8").strip()
            except (OSError, UnicodeError) as exc:
                raise ValueError("cannot read old native systemConfig evidence") from exc
            if configured_system != old["current_system"] or not Path(configured_system).is_absolute():
                raise ValueError("profile and current native system disagree")
            health = wave_health.check_health()
            if _cancelled(): return _finish(run, commit, "interrupted", health, old, {}, "preflight cancellation")
            if not health.get("ok"): return _finish(run, commit, "preflight_failed", health, old, {}, "preflight health")
            if _cancelled(): return _finish(run, commit, "interrupted", health, old, {}, "pre-validation cancellation")
            phase = "validation"
            for args, name in ((["nix-check"], "nix-check.log"), (["nix-eval", "renekton"], "nix-eval.log")):
                result = _nix(repo, args, run, name)
                if result.interrupted or _cancel:
                    return _finish(run, commit, "interrupted", health, old, {}, name)
                if result.returncode: return _finish(run, commit, "validation_failed", health, old, {}, name)
            if _cancelled(): return _finish(run, commit, "interrupted", health, old, {}, "preparation cancellation")
            if _commit(repo) != commit: raise ValueError("HEAD changed during validation")
            _clean_upstream(repo, commit)
            if not common.same_system(common.snapshot_system(), old): raise ValueError("system changed during validation")
            temp_root = Path(tempfile.mkdtemp(prefix=f"wave-{os.getuid()}-", dir="/private/tmp")).resolve(); temp_root.chmod(0o700)
            child = temp_root / "canary"; child.mkdir(mode=0o700)
            (child / "wave-log-dir").write_text(str(run.resolve()) + "\n", encoding="utf-8")
            (child / "wave-old-profile").write_text(old["profile_closure"] + "\n", encoding="utf-8")
            for item in child.iterdir(): item.chmod(0o600)
            flake = render_runtime_flake(repo, commit, child, run)
            _stage("locking runtime flake")
            lock_result = _nix(repo, ["nix", "flake", "lock", f"path:{flake}"], run, "runtime-flake-lock.log")
            if lock_result.interrupted or _cancel: return _finish(run, commit, "interrupted", health, old, {}, "runtime flake lock")
            if lock_result.returncode: return _finish(run, commit, "validation_failed", health, old, {}, "runtime flake lock")
            meta = _meta(repo, flake, run, child, commit)
            profile = Path(meta["profile_closure"])
            wrapper = profile / "activate"
            native = profile / "activate-rs"
            system = Path(meta["system_closure"])
            native_activate = system / "activate"
            new = {"profile_closure": str(profile), "current_system": str(system), "profile_link": None}
            profile_already_active = old["profile_closure"] == new["profile_closure"]
            if not profile_already_active:
                _stage("building targeted profile, deploy-rs, and sudo packages")
                build = _nix(repo, ["nix", "build", "--no-link", "--no-write-lock-file", f"path:{flake}#profile", f"path:{flake}#deploy-rs", f"path:{flake}#sudo"], run, "build.log")
                if build.interrupted or _cancel: return _finish(run, commit, "interrupted", health, old, new, "targeted build")
                if build.returncode: return _finish(run, commit, "validation_failed", health, old, new, "targeted build")
            # An identical active profile is already realized; skip its redundant build.
            if not (profile.is_dir() and wrapper.is_file() and os.access(wrapper, os.X_OK) and native.is_file() and os.access(native, os.X_OK) and system.is_dir() and native_activate.is_file() and os.access(native_activate, os.X_OK)):
                raise ValueError("profile lacks executable activation entries")
            if wrapper.resolve(strict=True) != native_activate.resolve(strict=True):
                raise ValueError("profile wrapper is not bound to the declared native system")
            # The final gate is repeated after all evaluation/build activity.
            if _cancelled(): return _finish(run, commit, "interrupted", health, old, new, "pre-deployment cancellation")
            if _commit(repo) != commit: raise ValueError("HEAD changed before deployment")
            _clean_upstream(repo, commit)
            if not common.same_system(common.snapshot_system(), old): raise ValueError("system changed before deployment")
            health = wave_health.check_health()
            if _cancelled(): return _finish(run, commit, "interrupted", health, old, new, "final baseline cancellation")
            if not health.get("ok"): return _finish(run, commit, "preflight_failed", health, old, new, "final baseline health")
            if old["profile_closure"] == new["profile_closure"]:
                final_health = wave_health.check_health()
                if _cancelled():
                    return _finish(run, commit, "interrupted", final_health, old, new, "noop cancellation")
                actual = common.snapshot_system()
                if (final_health.get("ok") and common.same_system(actual, old)
                        and actual.get("profile_closure") == new["profile_closure"]
                        and actual.get("current_system") == new["current_system"]):
                    new = {**new, "changed": False, "note": "already_current"}
                    return _finish(run, commit, "success", final_health, old, new)
                return _finish(run, commit, "critical", final_health, old, new, "noop state or health changed")
            if not shutil.which("nix") or not shutil.which("ssh"):
                raise ValueError("deploy-rs requires nix and ssh in PATH; run via devenv shell")
            context = {"run_dir": str(run.resolve()), "temp_path": str(child.resolve()),
                       "new_profile_closure": new["profile_closure"], "new_system": new["current_system"],
                       "old": old}
            common.atomic_json(run / "context.json", context)
            common.atomic_json(STATE / "active.json", {"commit": commit, "run_dir": str(run), "old": old, "new": new})
            active_owned = True; launched = True
            phase = "native"
            cli = _deploy(repo, run, meta["deploy_package"])
            if cli.interrupted:
                _cancel = True
            if cli.returncode != 0 or cli.interrupted or cli.timed_out: _cancel_marker()
            outcome = wave_monitor.observe_deployment(context, cli, baseline_health=health, interrupted=lambda: _cancel, on_update=_stage)
            code, active_owned = _finalize(run, active_owned, outcome, commit, old, new)
            return code
        except KeyboardInterrupt:
            _cancel = True; _cancel_marker()
            if launched and run is not None:
                if isinstance(context, dict):
                    outcome = wave_monitor.observe_deployment(context, wave_process.CommandResult(1, interrupted=True), baseline_health=health, interrupted=lambda: _cancel, on_update=_stage)
                    code, active_owned = _finalize(run, active_owned, outcome, commit, old, new)
                    return code
            if run is not None: return _finish(run, commit, "interrupted", health, old, new, "interrupt")
            return 130
        except Exception as exc:
            if launched and run is not None and isinstance(context, dict):
                with contextlib.suppress(OSError): _cancel_marker()
                outcome = wave_monitor.observe_deployment(context, wave_process.CommandResult(1), baseline_health=health, interrupted=lambda: _cancel, on_update=_stage)
                code, active_owned = _finalize(run, active_owned, outcome, commit, old, new)
                return code
            if run is not None:
                if isinstance(exc, InterruptedError) or _cancel:
                    result = "interrupted"
                else:
                    result = "critical" if phase == "native" else ("validation_failed" if phase == "validation" else "preflight_failed")
                return _finish(run, commit, result, health, old, new, str(exc))
            print(str(exc), file=sys.stderr); return 10
    finally:
        if temp_root is not None and not active_owned:
            try:
                _cleanup(temp_root)
            except OSError as exc:
                print(f"cleanup failed; retain evidence at {temp_root}: {exc}", file=sys.stderr)
        _current_run = None
        for sig, handler in old_handlers.items(): signal.signal(sig, handler)
        with contextlib.suppress(OSError): os.close(lock_fd)


if __name__ == "__main__":
    raise SystemExit(safe_switch())
