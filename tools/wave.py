#!/usr/bin/env python3
"""The deliberately small public Wave command line."""
from __future__ import annotations

import argparse
import json
import sys

import wave_health


def _health_json() -> int:
    result = wave_health.check_health()
    sys.stdout.write(json.dumps(result, separators=(",", ":"), sort_keys=True) + "\n")
    return 0 if result.get("ok") else 1


def _health() -> int:
    result = wave_health.check_health()
    checks = result.get("checks", {})
    names = ("network", "dns", "https", "tailscale", "openclaw")
    for name in names:
        item = checks.get(name, {})
        state = "ok" if item.get("ok") else "FAIL"
        print(f"{name:10} {state:4} {item.get('detail', 'unavailable')}")
    print("summary: " + ("healthy" if result.get("ok") else "unhealthy"))
    return 0 if result.get("ok") else 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="wave")
    sub = parser.add_subparsers(dest="command")
    health = sub.add_parser("health", help="run read-only host health checks")
    health.add_argument("--json", action="store_true", help="emit one JSON object")
    sub.add_parser("safe-switch", help="validate and safely activate Renekton")
    args = parser.parse_args(argv)
    if args.command == "health" and args.json:
        return _health_json()
    if args.command == "health":
        return _health()
    if args.command == "safe-switch":
        from wave_switch import safe_switch

        return safe_switch()
    parser.print_help()
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
