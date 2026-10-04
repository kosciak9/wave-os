"""Explicit reconciliation of interrupted deployment with a healthy manual activation."""
from __future__ import annotations

import fcntl
import hashlib
import json
import os
import platform
import re
import stat
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

import wave_common as common
import wave_health
import wave_switch as switch


def _digest(value: dict) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def _private_file(path: Path, *, native: bool = False) -> bytes:
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, "rb") as source:
        info = os.fstat(source.fileno())
        # Native deploy-rs files inherit its umask inside the private run directory.
        forbidden = 0o022 if native else 0o077
        owners = {os.getuid(), 0} if native else {os.getuid()}
        if not stat.S_ISREG(info.st_mode) or info.st_uid not in owners or info.st_mode & forbidden:
            raise ValueError(f"nonprivate evidence file: {path.name}")
        data = source.read(2 * 1024 * 1024 + 1)
        if len(data) > 2 * 1024 * 1024:
            raise ValueError("oversized recovery evidence")
        return data


def _json(path: Path) -> dict:
    value = json.loads(_private_file(path))
    if not isinstance(value, dict):
        raise ValueError("recovery evidence must be an object")
    return value


def _evidence(run: Path, *, require_pid: bool = True) -> dict:
    paths = [run / "context.json", *sorted(run.glob("activate_activate_*.log"))]
    if require_pid or (run / "native.pid").exists() or (run / "native.pid").is_symlink():
        paths.append(run / "native.pid")
    if (run / "result.json").exists() or (run / "result.json").is_symlink():
        context = switch._run_context(run)
        result = _json(run / "result.json")
        if (result.get("result") not in {"critical", "interrupted", "success", "deploy_failed_rolled_back", "deploy_failed_unchanged"}
                or result.get("commit") != context["commit"] or result.get("log_dir") != str(run)
                or result.get("old") != context["old"]
                or result.get("new", {}).get("profile_closure") != context["new_profile_closure"]
                or result.get("new", {}).get("current_system") != context["new_system"]):
            raise ValueError("original result has invalid deployment identity/outcome")
        paths.append(run / "result.json")
    return {p.name: hashlib.sha256(_private_file(p, native=p.name == "native.pid" or p.name.startswith("activate_activate_"))).hexdigest() for p in paths}


def _quiescent(run: Path, context: dict, *, allow_not_started: bool = False) -> str:
    native = common.activation_result(run)
    unchanged = allow_not_started and native == "not_started" and not any(run.glob("activate_activate_*.log"))
    if native not in {"rolled_back", "confirmed"} and not unchanged:
        raise ValueError(f"native evidence is not terminal: {native}")
    allowed_process = {"absent", "exited"} if unchanged else {"exited"}
    if common.process_state(run) not in allowed_process:
        raise ValueError("native activation PID is alive, missing, or ambiguous")
    # The foreground deploy process was not recorded by older Wave versions.
    # Inspect argv as well as native.pid, including orphaned SSH/monitor children.
    result = subprocess.run(["/bin/ps", "-ww", "-axo", "pid=,command="], stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, text=True, timeout=5, check=False)
    if result.returncode:
        raise ValueError("cannot inspect old deployment processes")
    temp = context.get("temp_path")
    if not isinstance(temp, str) or re.fullmatch(r"/private/tmp/wave-[0-9]+-[A-Za-z0-9_-]+/canary", temp) is None:
        raise ValueError("activation temporary path is invalid")
    for line in result.stdout.splitlines():
        pid, command = line.strip().split(None, 1)
        if int(pid) != os.getpid() and any(token in command for token in (str(run), temp, context["new_profile_closure"])):
            raise ValueError("a relevant old deployment process is still alive")
    return native


def _snapshot_valid(state: dict) -> bool:
    if set(state) != {"profile_link", "profile_closure", "current_system"}:
        return False
    link = state["profile_link"]
    return (isinstance(link, str) and (re.fullmatch(r"system-[0-9]+-link", link) is not None
            or (link.startswith("/nix/store/") and switch.SAFE_PATH.fullmatch(link) is not None))
            and all(isinstance(state[k], str) and state[k].startswith("/nix/store/")
                    and switch.SAFE_PATH.fullmatch(state[k]) for k in ("profile_closure", "current_system")))


def _manual_snapshot(state: dict) -> None:
    if not _snapshot_valid(state):
        raise ValueError("current snapshot is incomplete or invalid")
    profile = Path(state["profile_closure"])
    system = Path(state["current_system"])
    config = profile / "systemConfig"
    coherent = profile == system or (config.is_file() and config.read_text().strip() == str(system))
    if not coherent or not system.is_dir() or not os.access(system / "activate", os.X_OK):
        raise ValueError("current profile/current-system do not identify a coherent native system")


def _healthy(health: dict) -> bool:
    if not isinstance(health, dict):
        return False
    checks = health.get("checks")
    return (health.get("ok") is True and isinstance(checks, dict)
            and set(checks) == {"network", "dns", "https", "tailscale", "openclaw"}
            and all(isinstance(item, dict) and item.get("ok") is True for item in checks.values()))


def validated_record(run: Path, context: dict, *, allow_missing_event: bool = False) -> dict | None:
    record_path = run / "reconciliation.json"
    event_path = run / "reconciliation-event.json"
    if not any(p.exists() or p.is_symlink() for p in (record_path, event_path)):
        return None
    switch._private_directory(run, create=False)
    record = _json(record_path)
    event = (_json(event_path) if event_path.exists() or event_path.is_symlink() or not allow_missing_event else None)
    timestamp = record.get("timestamp")
    if not isinstance(timestamp, str) or datetime.fromisoformat(timestamp.replace("Z", "+00:00")).tzinfo is None:
        raise ValueError("invalid reconciliation timestamp")
    plan = record.get("plan")
    health = record.get("health_window")
    if (set(record) != {"result", "timestamp", "plan", "approval", "health_window"}
            or record.get("result") != "reconciled_manual_activation"
            or not isinstance(record.get("timestamp"), str)
            or not isinstance(plan, dict) or record.get("approval") != _digest(plan)
            or set(plan) != {"version", "run_dir", "commit", "context", "active", "active_sha256", "native", "evidence", "state"}
            or plan.get("version") != 1 or plan.get("run_dir") != str(run)
            or plan.get("commit") != context["commit"] or plan.get("context") != context
            or not isinstance(plan.get("active"), dict) or not switch._active_matches(plan["active"], run, context)
            or not isinstance(plan.get("active_sha256"), str) or re.fullmatch(r"[0-9a-f]{64}", plan["active_sha256"]) is None
            or plan.get("native") != _quiescent(run, context)
            or plan.get("evidence") != _evidence(run)
            or not isinstance(plan.get("state"), dict) or not _snapshot_valid(plan["state"])
            or common.same_system(plan["state"], context["old"])
            or not isinstance(health, dict) or set(health) != {"seconds", "samples", "health"}
            or health.get("seconds") != common.ROLLBACK_HEALTH_WINDOW
            or type(health.get("samples")) is not int
            or health["samples"] < common.HEALTH_STREAK or not _healthy(health.get("health", {}))
            or (event is not None and event != {"event": "reconciled_manual_activation", "timestamp": record["timestamp"],
                                               "record_sha256": _digest(record)})):
        raise ValueError("manual reconciliation evidence is corrupt, changed, or incomplete")
    return record


def _other_history(selected: Path) -> None:
    runs, truncated = switch._run_dirs()
    if truncated:
        raise ValueError("recovery history scan reached its safety bound")
    for run in runs:
        if run == selected:
            continue
        has_result = (run / "result.json").exists() or (run / "result.json").is_symlink()
        if not switch._native_evidence(run) and (not (run / "context.json").exists() or not has_result):
            if any((run / name).exists() or (run / name).is_symlink()
                   for name in ("reconciliation.json", "reconciliation-event.json")):
                raise ValueError("reconciliation without native evidence")
            continue
        switch._private_directory(run, create=False)
        context = switch._run_context(run)
        if validated_record(run, context) is not None:
            continue
        _evidence(run, require_pid=False)
        native = _quiescent(run, context, allow_not_started=True)
        result = _json(run / "result.json")
        expected = {"confirmed": "success", "rolled_back": "deploy_failed_rolled_back",
                    "not_started": "deploy_failed_unchanged"}[native]
        state = result.get("state")
        if (result.get("result") != expected or result.get("commit") != context["commit"]
                or result.get("log_dir") != str(run) or result.get("old") != context["old"]
                or result.get("new", {}).get("profile_closure") != context["new_profile_closure"]
                or result.get("new", {}).get("current_system") != context["new_system"]
                or not _healthy(result.get("health", {})) or not isinstance(state, dict)
                or not _snapshot_valid(state)
                or (native in {"rolled_back", "not_started"} and not common.same_system(state, context["old"]))
                or (native == "confirmed" and (state["profile_closure"] != context["new_profile_closure"]
                    or state["current_system"] != context["new_system"] or not switch._confirmed_health_approval(run)))):
            raise ValueError("unrelated deployment has unresolved/conflicting terminal evidence")


def _plan(*, retry_approval: str | None = None) -> tuple[Path, dict]:
    active_bytes = _private_file(switch.STATE / "active.json")
    active = json.loads(active_bytes)
    if not isinstance(active, dict):
        raise ValueError("active marker must be an object")
    run = Path(active.get("run_dir", ""))
    switch._private_directory(run, create=False)
    context = switch._run_context(run)
    if not switch._active_matches(active, run, context):
        raise ValueError("active marker does not match activation context")
    persisted = validated_record(run, context, allow_missing_event=retry_approval is not None)
    if persisted is not None and (retry_approval is None or persisted["approval"] != retry_approval):
        raise ValueError("persisted reconciliation still has an active marker; explicit retry requires its original approval fingerprint")
    native = _quiescent(run, context)
    evidence = _evidence(run)
    _other_history(run)
    state = common.snapshot_system()
    _manual_snapshot(state)
    if common.same_system(state, context["old"]):
        raise ValueError("current state matches old snapshot; use normal Wave rollback recovery")
    plan = {"version": 1, "run_dir": str(run), "commit": context["commit"],
            "context": context, "active": active, "active_sha256": hashlib.sha256(active_bytes).hexdigest(),
            "native": native, "evidence": evidence, "state": state}
    if persisted is not None and persisted["plan"] != plan:
        raise ValueError("persisted reconciliation does not match exact current marker/context/evidence/native/snapshot")
    return run, plan


def _persisted_evidence(run: Path) -> dict:
    return {name: hashlib.sha256(_private_file(run / name)).hexdigest()
            for name in ("reconciliation.json", "reconciliation-event.json")
            if (run / name).exists() or (run / name).is_symlink()}


def _sync_directory(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def recover(*, accept_manual: str | None = None) -> int:
    if accept_manual is not None and re.fullmatch(r"[0-9a-f]{64}", accept_manual) is None:
        print("--accept-manual requires the SHA256 plan displayed by wave recover", file=sys.stderr)
        return 2
    if platform.system() != "Darwin" or platform.machine() != "arm64" or os.geteuid() == 0:
        print("wave recover requires a local non-root Darwin arm64 user", file=sys.stderr)
        return 10
    fd = None
    try:
        for path in (switch.STATE, switch.STATE / "logs", switch.LOGS):
            switch._private_directory(path, create=False)
        # Read-only inspection does not create a missing lock or state directory.
        fd = os.open(switch.STATE / "safe-switch.lock", os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
        lock_info = os.fstat(fd)
        if (not stat.S_ISREG(lock_info.st_mode) or lock_info.st_uid != os.getuid()
                or lock_info.st_mode & 0o077):
            raise ValueError("singleton lock is not a private regular file")
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        run, plan = _plan(retry_approval=accept_manual)
        persisted = validated_record(run, plan["context"], allow_missing_event=accept_manual is not None)
        persistence = _persisted_evidence(run)
        approval = _digest(plan)
        print(json.dumps({"plan": plan, "fingerprint": approval}, sort_keys=True, indent=2))
        if accept_manual is not None and accept_manual != approval:
            raise ValueError("approval does not match current plan; inspect wave recover again")
        started = time.monotonic()
        samples = 0
        while True:
            if _plan(retry_approval=accept_manual) != (run, plan) or _persisted_evidence(run) != persistence:
                raise ValueError("snapshot, marker, or original evidence changed during health window")
            health = wave_health.check_health()
            if not _healthy(health):
                raise ValueError("current system is unhealthy; reconciliation is not eligible")
            samples += 1
            if _plan(retry_approval=accept_manual) != (run, plan) or _persisted_evidence(run) != persistence:
                raise ValueError("snapshot, marker, or original evidence changed during health probe")
            if time.monotonic() - started >= common.ROLLBACK_HEALTH_WINDOW and samples >= common.HEALTH_STREAK:
                break
            time.sleep(common.HEALTH_INTERVAL)
        if accept_manual is None:
            print(f"Eligible: coherent current system healthy and stable for {common.ROLLBACK_HEALTH_WINDOW}s; "
                  "native and relevant deployment processes exited; unrelated history resolved.")
            print("Health checks: " + ", ".join(f"{name}=ok" for name in health["checks"]))
            print(f"Explicit acceptance: wave recover --accept-manual {approval}")
            print("Read-only: no evidence or active marker changed.")
            return 0
        record = persisted or {"result": "reconciled_manual_activation", "timestamp": common.utc_now(),
                  "plan": plan, "approval": approval,
                  "health_window": {"seconds": common.ROLLBACK_HEALTH_WINDOW, "samples": samples, "health": health}}
        if _plan(retry_approval=accept_manual) != (run, plan) or _persisted_evidence(run) != persistence:
            raise ValueError("recovery plan changed before persistence")
        if persisted is None:
            common.atomic_json(run / "reconciliation.json", record)
        _sync_directory(run)
        if "reconciliation-event.json" not in persistence:
            common.atomic_json(run / "reconciliation-event.json", {
                "event": record["result"], "timestamp": record["timestamp"], "record_sha256": _digest(record)})
        _sync_directory(run)
        if (validated_record(run, plan["context"]) != record
                or _json(switch.STATE / "active.json") != plan["active"]
                or not common.same_system(common.snapshot_system(), plan["state"])):
            raise ValueError("final reconciliation/active marker/state recheck failed")
        _other_history(run)
        if (hashlib.sha256(_private_file(switch.STATE / "active.json")).hexdigest() != plan["active_sha256"]
                or not common.same_system(common.snapshot_system(), plan["state"])
                or _quiescent(run, plan["context"]) != plan["native"]
                or _evidence(run) != plan["evidence"]):
            raise ValueError("active marker or snapshot changed before removal")
        (switch.STATE / "active.json").unlink()
        _sync_directory(switch.STATE)
        print("reconciled_manual_activation; original deployment/native evidence preserved; active marker retired")
        return 0
    except (OSError, ValueError, TypeError, KeyError, AttributeError, subprocess.SubprocessError) as exc:
        print(f"wave recover blocked: {exc}. No activation or restart performed.", file=sys.stderr)
        return 10
    finally:
        if fd is not None:
            os.close(fd)
