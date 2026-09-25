"""Read-only health checks for the Renekton host."""

from __future__ import annotations

import concurrent.futures
import ipaddress
import json
import shutil
import subprocess
import time
from datetime import datetime, timezone
from typing import Callable


_CURL = "/usr/bin/curl"
_DSCACHEUTIL = "/usr/bin/dscacheutil"
_ROUTE = "/sbin/route"
_TAILSCALE = "/run/current-system/sw/bin/tailscale"
_HTTPS_ENDPOINTS = (
    "https://www.cloudflare.com/cdn-cgi/trace",
    "https://www.google.com/generate_204",
)
_MAX_OPENCLAW_RESPONSE = 65536


def _now() -> float:
    return time.monotonic()


def _result(ok: bool, detail: str, started: float) -> dict:
    return {
        "ok": ok,
        "detail": detail,
        "duration_ms": round(max(0.0, (_now() - started) * 1000), 1),
    }


def _remaining(deadline: float) -> float:
    return deadline - _now()


def _run(command: list[str], deadline: float) -> subprocess.CompletedProcess[str] | None:
    remaining = _remaining(deadline)
    if remaining <= 0:
        return None
    try:
        return subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=min(3.0, remaining),
            check=False,
        )
    except (FileNotFoundError, OSError, subprocess.TimeoutExpired):
        return None


def _network(deadline: float) -> dict:
    started = _now()
    if not shutil.which(_ROUTE):
        return _result(False, "route tool unavailable", started)
    probe_deadline = min(deadline, started + 3.0)
    ipv4_deadline = min(probe_deadline, started + 1.5)
    ipv4 = _run([_ROUTE, "-n", "get", "default"], ipv4_deadline)
    if ipv4 is not None and ipv4.returncode == 0:
        return _result(True, "default route available", started)
    ipv6 = _run([_ROUTE, "-n", "get", "-inet6", "default"], probe_deadline)
    if ipv6 is not None and ipv6.returncode == 0:
        return _result(True, "default route available", started)
    return _result(False, "no default route", started)


def _dns(deadline: float) -> dict:
    started = _now()
    if not shutil.which(_DSCACHEUTIL):
        return _result(False, "DNS tool unavailable", started)
    completed = _run(
        [_DSCACHEUTIL, "-q", "host", "-a", "name", "example.com"], deadline
    )
    if completed is None or completed.returncode != 0:
        return _result(False, "DNS resolution failed", started)
    for line in completed.stdout.splitlines():
        key, separator, value = line.partition(":")
        if separator and key.strip() in {"ip_address", "ipv6_address"}:
            try:
                ipaddress.ip_address(value.strip())
            except ValueError:
                continue
            return _result(True, "DNS resolution succeeded", started)
    return _result(False, "DNS returned no address", started)


def _https_endpoint(url: str, deadline: float) -> dict:
    if not shutil.which(_CURL):
        return {"url": url, "ok": False}
    completed = _run(
        [
            _CURL,
            "-sS",
            "-f",
            "--connect-timeout",
            "3",
            "--max-time",
            "3",
            "--output",
            "/dev/null",
            "--write-out",
            "%{http_code}",
            "--proto",
            "=https",
            url,
        ],
        deadline,
    )
    if completed is None:
        return {"url": url, "ok": False}
    try:
        status = int(completed.stdout.strip())
    except ValueError:
        return {"url": url, "ok": False}
    return {
        "url": url,
        "ok": completed.returncode == 0 and 200 <= status < 400,
        "status": status,
    }


def _tailscale(deadline: float) -> dict:
    started = _now()
    binary = _TAILSCALE if shutil.which(_TAILSCALE) else shutil.which("tailscale")
    if not binary:
        return _result(False, "Tailscale tool unavailable", started)
    completed = _run([binary, "status", "--json"], deadline)
    if completed is None or completed.returncode != 0:
        return _result(False, "Tailscale status unavailable", started)
    try:
        status = json.loads(completed.stdout)
    except (TypeError, ValueError):
        return _result(False, "Tailscale status invalid", started)
    if not isinstance(status, dict):
        return _result(False, "Tailscale status invalid", started)
    warnings = status.get("Health", [])
    warning_count = len(warnings) if isinstance(warnings, list) else 1
    backend = status.get("BackendState")
    normalized_backend = (
        backend if isinstance(backend, str) and backend in {"Running", "Stopped", "Starting"}
        else "unknown"
    )
    result = _result(
        normalized_backend == "Running" and warning_count == 0,
        "Tailscale running" if normalized_backend == "Running" and warning_count == 0 else "Tailscale unhealthy",
        started,
    )
    result["detail"] = f"backend={normalized_backend}, warnings={warning_count}"
    return result


def _openclaw_endpoint(path: str, deadline: float) -> dict:
    result: dict[str, object] = {"ok": False}
    if _remaining(deadline) <= 0:
        return result
    if not shutil.which(_CURL):
        return result
    completed = _run(
        [
            _CURL,
            "-sS",
            "--noproxy",
            "*",
            "--connect-timeout",
            "3",
            "--max-time",
            "3",
            "--max-filesize",
            str(_MAX_OPENCLAW_RESPONSE),
            "--write-out",
            "\nWAVE_STATUS:%{http_code}",
            f"http://127.0.0.1:18789{path}",
        ],
        deadline,
    )
    if completed is None:
        return result
    body, separator, status_text = completed.stdout.rpartition("\nWAVE_STATUS:")
    if not separator:
        return result
    try:
        status = int(status_text.strip())
    except ValueError:
        return result
    result["status"] = status
    body_size_ok = len(body.encode()) <= _MAX_OPENCLAW_RESPONSE
    if completed.returncode == 0 and 200 <= status < 300 and body_size_ok:
        try:
            result["ok"] = json.loads(body).get("ok") is True
        except (AttributeError, TypeError, ValueError):
            pass
    return result


def check_health(*, deadline: float | None = None) -> dict:
    """Run all host probes concurrently and return safe, structured results."""
    started = _now()
    deadline = min(deadline, started + 4.0) if deadline is not None else started + 4.0
    checks: dict = {
        "network": _result(False, "deadline exceeded", started),
        "dns": _result(False, "deadline exceeded", started),
        "tailscale": _result(False, "deadline exceeded", started),
    }
    probes = {
        "network": lambda: _network(deadline),
        "dns": lambda: _dns(deadline),
        "https_cloudflare": lambda: _https_endpoint(_HTTPS_ENDPOINTS[0], deadline),
        "https_google": lambda: _https_endpoint(_HTTPS_ENDPOINTS[1], deadline),
        "tailscale": lambda: _tailscale(deadline),
        "openclaw_healthz": lambda: _openclaw_endpoint("/healthz", deadline),
        "openclaw_startupz": lambda: _openclaw_endpoint("/startupz", deadline),
    }
    with concurrent.futures.ThreadPoolExecutor(max_workers=7) as executor:
        futures = {
            name: executor.submit(probe)
            for name, probe in probes.items()
            if _remaining(deadline) > 0
        }
        for name, future in futures.items():
            try:
                checks[name] = future.result(timeout=max(0.0, _remaining(deadline)))
            except Exception:
                checks[name] = _result(False, "probe failed", started)
    https_endpoints = [
        checks.pop("https_cloudflare", _result(False, "deadline exceeded", started)),
        checks.pop("https_google", _result(False, "deadline exceeded", started)),
    ]
    https_result = _result(
        sum(endpoint.get("ok", False) for endpoint in https_endpoints) >= 1,
        "HTTPS available"
        if any(endpoint.get("ok") for endpoint in https_endpoints)
        else "HTTPS unavailable",
        started,
    )
    https_result["endpoints"] = [
        {"url": _HTTPS_ENDPOINTS[index], **endpoint}
        for index, endpoint in enumerate(https_endpoints)
    ]
    checks["https"] = https_result
    openclaw_endpoints = {
        "healthz": checks.pop("openclaw_healthz", _result(False, "deadline exceeded", started)),
        "startupz": checks.pop("openclaw_startupz", _result(False, "deadline exceeded", started)),
    }
    openclaw_result = _result(
        all(endpoint.get("ok", False) for endpoint in openclaw_endpoints.values()),
        "OpenClaw healthy"
        if all(endpoint.get("ok", False) for endpoint in openclaw_endpoints.values())
        else "OpenClaw unhealthy",
        started,
    )
    openclaw_result["endpoints"] = openclaw_endpoints
    checks["openclaw"] = openclaw_result
    checks = {
        name: checks[name]
        for name in ("network", "dns", "https", "tailscale", "openclaw")
    }
    return {
        "ok": all(check["ok"] for check in checks.values()),
        "timestamp": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "checks": checks,
    }


def wait_for_health(
    *,
    window_seconds: float,
    interval_seconds: float = 5,
    required_successes: int = 3,
    cancelled: Callable[[], bool] | None = None,
    on_sample: Callable[[dict, int, int], None] | None = None,
) -> dict:
    """Sample health until a consecutive-success window or the deadline."""
    if interval_seconds <= 0:
        raise ValueError("interval_seconds must be positive")
    if required_successes <= 0:
        raise ValueError("required_successes must be positive")
    start = _now()
    end = start + max(0.0, float(window_seconds))
    attempts = 0
    streak = 0
    last: dict = {}
    was_cancelled = False
    next_start = start
    while _now() < end:
        if cancelled is not None and cancelled():
            was_cancelled = True
            break
        if _now() >= end:
            break
        attempts += 1
        last = check_health(deadline=min(end, _now() + 4.0))
        sample_streak = streak + 1 if last.get("ok") else 0
        if cancelled is not None and cancelled():
            was_cancelled = True
            break
        if on_sample is not None:
            on_sample(last, attempts, sample_streak)
        if cancelled is not None and cancelled():
            was_cancelled = True
            break
        if _now() >= end:
            break
        streak = sample_streak
        if streak >= required_successes:
            break
        next_start += interval_seconds
        while _now() < min(end, next_start):
            if cancelled is not None and cancelled():
                was_cancelled = True
                break
            time.sleep(min(0.1, max(0.0, min(end, next_start) - _now())))
        if was_cancelled:
            break
    elapsed = _now() - start
    return {
        "ok": not was_cancelled and streak >= required_successes and _now() <= end,
        "cancelled": was_cancelled,
        "streak": streak,
        "attempts": attempts,
        "elapsed_seconds": round(max(0.0, elapsed), 3),
        "health": last,
    }
