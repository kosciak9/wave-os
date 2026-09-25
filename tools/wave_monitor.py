"""Foreground, read-only observer for native safe-switch activation."""

from __future__ import annotations

import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

import wave_common as common
import wave_health as health


@dataclass(frozen=True)
class DeploymentOutcome:
    result: str
    code: int
    health: dict
    state: dict
    error: str | None = None
    terminal: bool = False


def _safe_load(path: Path) -> dict | None:
    try:
        if not path.is_file():
            return None
        value = common.load_json(path)
        return value if isinstance(value, dict) else None
    except (OSError, ValueError, TypeError, UnicodeError):
        return None


def _old(actual: dict, expected: dict) -> bool:
    return common.same_system(actual, expected)


def _new(actual: dict, context: dict) -> bool:
    return (actual.get("profile_closure") == context.get("new_profile_closure")
            and actual.get("current_system") == context.get("new_system"))


def _health_window(window: float, on_update: Callable[[str], None]) -> dict:
    last_notice = 0.0

    def sample(item: dict, attempt: int, streak: int) -> None:
        nonlocal last_notice
        now = time.monotonic()
        if now - last_notice >= 15 or streak >= common.HEALTH_STREAK:
            on_update(f"health verification: sample {attempt}, streak {streak}/{common.HEALTH_STREAK}")
            last_notice = now

    return health.wait_for_health(
        window_seconds=window,
        interval_seconds=common.HEALTH_INTERVAL,
        required_successes=common.HEALTH_STREAK,
        cancelled=lambda: False,
        on_sample=sample,
    )


def _cli_bad(cli_result: object) -> tuple[bool, bool]:
    try:
        interrupted = bool(getattr(cli_result, "interrupted", False))
        timed_out = bool(getattr(cli_result, "timed_out", False))
        return int(getattr(cli_result, "returncode")) != 0 or interrupted or timed_out, interrupted
    except Exception:
        return True, False


def _read_native_state(run: Path, *, wait_for_logs: bool = False) -> tuple[str, str, dict]:
    if wait_for_logs:
        time.sleep(1.0)
    return common.process_state(run), common.activation_result(run), common.snapshot_system()


def observe_deployment(
    context: dict,
    cli_result: object,
    *,
    baseline_health: dict,
    interrupted: Callable[[], bool],
    on_update: Callable[[str], None],
) -> DeploymentOutcome:
    """Observe an already-started deployment without operating generations."""
    if not isinstance(context, dict):
        return DeploymentOutcome("critical", 40, baseline_health, common.snapshot_system(), "invalid deployment context")
    try:
        run = Path(context["run_dir"])
    except (KeyError, TypeError, ValueError):
        return DeploymentOutcome("critical", 40, baseline_health, common.snapshot_system(), "invalid run directory")
    old = context.get("old")
    if not isinstance(old, dict):
        return DeploymentOutcome("critical", 40, baseline_health, common.snapshot_system(), "invalid old snapshot")

    cli_bad, cli_interrupted = _cli_bad(cli_result)
    fence = run / "cancelled"
    if cli_bad:
        try:
            fence.touch(mode=0o600, exist_ok=True)
        except OSError:
            return DeploymentOutcome("critical", 40, baseline_health, common.snapshot_system(), "cannot write cancellation fence")

    started = time.monotonic()
    deadline = started + common.ACTIVATION_TIMEOUT + common.CONFIRM_TIMEOUT + 120
    try:
        canary = common.canary_path(context)
        armed = canary.stat().st_mtime
        deadline = min(deadline, started + max(0.0, armed + common.CONFIRM_TIMEOUT - time.time()) + 120)
    except (OSError, KeyError, ValueError):
        canary = None

    phase = ""
    notice_at = 0.0
    native = pid = "unknown"
    actual: dict = {}
    try:
        while True:
            pid, native, actual = _read_native_state(run)

            if native == "unknown" and pid in {"absent", "exited"}:
                # A completed-looking PID cannot make unreadable native evidence safe.
                pid, native, actual = _read_native_state(run, wait_for_logs=True)
                if native == "unknown":
                    return DeploymentOutcome("critical", 40, baseline_health, actual, "native state remains unknown")

            if native == "pending" and pid != "running":
                # A missing process with a pending log is not a safe terminal state.
                pid, native, actual = _read_native_state(run, wait_for_logs=True)
                if pid != "running" and native == "pending":
                    return DeploymentOutcome(
                        "critical",
                        40,
                        baseline_health,
                        actual,
                        "native process disappeared while pending",
                    )

            if native == "rollback_failed":
                return DeploymentOutcome("critical", 40, baseline_health, actual, "native rollback failed")

            now = time.monotonic()
            if native == "confirmed" and pid not in {"absent", "exited"}:
                text = "Native activation confirmed; waiting for native process to exit"
            elif native == "rolled_back":
                text = "Waiting for native deploy-rs rollback; no confirmation will be sent"
            elif native == "not_started":
                text = "Native activation has not started; checking for a safe abort"
            elif (
                native == "pending"
                and actual.get("profile_closure") == old.get("profile_closure")
                and not _old(actual, old)
            ):
                text = "Profile reverted; native reactivation is finishing"
            elif native == "pending" and cli_bad:
                text = "Waiting for deploy-rs timeout or native rollback; confirmation withheld"
            elif native == "unknown" or pid == "unknown":
                text = "Waiting for verifiable native activation state"
            else:
                text = f"Native activation {native}; process {pid}"
            if text != phase or now >= notice_at:
                on_update(text)
                phase, notice_at = text, now + 15
            if native != "unknown" and pid in {"absent", "exited"}:
                break
            if now >= deadline:
                return DeploymentOutcome("critical", 40, baseline_health, actual, "native activation observation deadline expired")
            time.sleep(0.25)
    except Exception:
        return DeploymentOutcome("critical", 40, baseline_health, common.snapshot_system(), "state observation failed")

    try:
        actual = common.snapshot_system()
    except Exception:
        return DeploymentOutcome("critical", 40, baseline_health, {}, "final state observation failed")
    if native == "rollback_failed":
        return DeploymentOutcome("critical", 40, baseline_health, actual, "native rollback failed")

    if native == "confirmed":
        approval = _safe_load(run / "health-approved.json")
        approved_health = approval.get("health") if approval else None
        proof = (
            not cli_bad and not cli_interrupted
            and approval is not None and isinstance(approval.get("timestamp"), str)
            and bool(approval.get("timestamp"))
            and isinstance(approved_health, dict) and approved_health.get("ok") is True
            and isinstance(approved_health.get("health"), dict)
            and approved_health["health"].get("ok") is True
            and isinstance(approved_health["health"].get("checks"), dict)
            and native == "confirmed" and pid in {"absent", "exited"} and _new(actual, context)
        )
        if not proof:
            return DeploymentOutcome("critical", 40, baseline_health, actual, "native confirmation proof incomplete")
        try:
            common.append_event(run, "deployment_observed_success")
        except Exception:
            return DeploymentOutcome("critical", 40, baseline_health, actual, "cannot record success proof")
        return DeploymentOutcome("success", 0, approved_health["health"], actual, terminal=True)

    if native not in {"rolled_back", "not_started"} or not _old(actual, old):
        return DeploymentOutcome("critical", 40, baseline_health, actual, "activation ended without safe terminal proof")

    # This fence is required even for a successful CLI: not_started is unexpected,
    # and a late privileged action must not act on an untouched old generation.
    try:
        fence.touch(mode=0o600, exist_ok=True)
    except OSError:
        return DeploymentOutcome("critical", 40, baseline_health, actual, "cannot write cancellation fence")
    if native == "not_started":
        try:
            was_interrupted = interrupted()
        except Exception:
            return DeploymentOutcome("critical", 40, baseline_health, actual, "interruption state unavailable")
        if cli_interrupted or was_interrupted:
            return DeploymentOutcome("interrupted", 130, baseline_health, actual, terminal=True)

    try:
        on_update("Verifying restored old-state health; recovery ignores the initial cancellation")
        recovery = _health_window(common.ROLLBACK_HEALTH_WINDOW, on_update)
        after = common.snapshot_system()
        after_pid = common.process_state(run)
        record = {**recovery, "latest_checks": recovery.get("health", {})}
        common.atomic_json(run / ("rollback-health.json" if native == "rolled_back" else "unchanged-health.json"), record)
        common.append_event(run, "rollback_health" if native == "rolled_back" else "unchanged_health", ok=bool(recovery.get("ok")))
    except Exception:
        return DeploymentOutcome("critical", 40, baseline_health, actual, "recovery health observation failed")
    recovered = (recovery.get("ok") is True and isinstance(recovery.get("health"), dict)
                 and recovery["health"].get("ok") is True and _old(after, old)
                 and after_pid in {"absent", "exited"})
    if recovered:
        result = "deploy_failed_rolled_back" if native == "rolled_back" else "deploy_failed_unchanged"
        return DeploymentOutcome(result, 30, recovery["health"], after, terminal=True)
    return DeploymentOutcome("critical", 40, recovery.get("health", {}), after, "old-state proof failed")
