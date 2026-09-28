"""Offline packaging smoke/latency check, NOT a substitute for live browser evaluation.

Usage: python3 bench_runtime.py /nix/store/.../bin/browser-decision [--out /tmp/rows.json]
Runs one resident Nix-built Kev process on 72 authored cases; records raw per-case
probabilities, latency and peak child RSS. Do not run concurrently with Laya.
"""
import argparse
import json
import os
import resource
import select
import statistics
import subprocess
import time
from pathlib import Path

CASES = [
    ("nav_docs", "Open the documentation section", "Documentation", "link", "CLICK", "Home | Products | Documentation | Support"),
    ("nav_pricing", "Find the pricing page", "Pricing", "link", "CLICK", "Plans | Pricing | Company | FAQ"),
    ("search", "Search for quarterly reports", "Search reports", "textbox", "TYPE_TEXT", "Reports page with search input empty and Search button"),
    ("submit", "Submit the filled search for invoices", "Search", "button", "CLICK", "Search invoices input value=invoices; Search button"),
    ("form_origin", "Set the flight origin to Boston", "From / origin", "textbox", "TYPE_TEXT", "Flight search: From empty, To empty, Departure date empty, Return date empty"),
    ("form_dest", "Set the flight destination to Denver", "To / destination", "textbox", "TYPE_TEXT", "Flight search: From, To empty, Departure date, Return date"),
    ("date", "Set the departure date to October 12", "Departure date", "textbox", "TYPE_TEXT", "Flight search: From, To, Departure date empty, Return date empty"),
    ("date_ambiguous", "Set the origin city to Boston; do not change the departure date", "From / origin", "textbox", "TYPE_TEXT", "Flight search: Departure city empty and Departure date empty and To"),
    ("history", "Continue after setting origin; next set destination to Denver", "To / destination", "textbox", "TYPE_TEXT", "Flight search: From value=Boston; To empty; Departure date empty"),
    ("next", "Go to the next page of results", "Next page", "link", "CLICK", "Results page 1 of 3, previous and next page links"),
    ("no_target", "Open billing settings; none of these controls lead to billing", None, None, "BLOCKED", "Profile page; billing settings not available"),
    ("done", "The requested report is already open; stop interacting", None, None, "DONE", "Quarterly report is open and fully visible"),
]
DISTRACTORS = [
    ("Home", "link"), ("Help", "link"), ("Contact", "link"), ("Departure airport", "textbox"),
    ("Departure date", "textbox"), ("Arrival date", "textbox"), ("From / origin", "textbox"),
    ("To / destination", "textbox"), ("Search", "button"), ("Search reports", "textbox"),
    ("Reset", "button"), ("Save", "button"), ("Privacy", "link"), ("Previous page", "link"),
    ("Open menu", "button"), ("Account", "link"), ("Results", "link"), ("Newsletter", "textbox"),
    ("Sort results", "button"), ("Booking", "link"), ("Next page", "link"),
    ("Documentation", "link"), ("Pricing", "link"), ("Continue", "button"),
    ("Calendar", "button"), ("Reports", "link"), ("Settings", "link"),
]


def cases():
    for count in (4, 12, 24):
        for history in (0, 3):
            for case, goal, label, role, op, text in CASES:
                controls = ([(label, role)] if label else []) + [item for item in DISTRACTORS if item != (label, role)]
                controls = controls[:count]
                if label:
                    controls.remove((label, role))
                    controls.insert((len(case) * 7 + count + history) % count, (label, role))
                state = f"Goal: {goal}\nPage: {text}\n"
                if history:
                    state += "Previous actions:\n- [input] Boston -> TYPE\n- [search] Search -> CLICK\n- [result] Observe -> WAIT\n"
                state += "Candidate elements:\n" + "\n".join(
                    f'[{i}] <{"input" if r == "textbox" else "a" if r == "link" else "button"}> role={r} "{name}"'
                    for i, (name, r) in enumerate(controls)
                )
                choices = [
                    f'{"TYPE_TEXT" if r == "textbox" else "CLICK"} [{i}] {name} ({r})'
                    for i, (name, r) in enumerate(controls)
                ] + ["DONE", "BLOCKED"]
                expected = f"{op} [{controls.index((label, role))}] {label} ({role})" if label else op
                yield {"state": state, "choices": choices}, (case, count, history, expected)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("program", type=Path)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    env = {**os.environ, "HF_HUB_OFFLINE": "1", "OMP_NUM_THREADS": "4"}
    rows = []
    start = time.perf_counter()
    with subprocess.Popen(
        [str(args.program), "kev"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, env=env,
    ) as worker:
        try:
            for request, (case, count, history, expected) in cases():
                worker.stdin.write((json.dumps(request) + "\n").encode())
                worker.stdin.flush()
                if not select.select([worker.stdout], [], [], 30)[0]:
                    raise TimeoutError(f"no model response within 30 seconds on {case}")
                raw = worker.stdout.readline()
                if not raw:
                    raise RuntimeError(f"worker exited early, status={worker.poll()}")
                answer = json.loads(raw)
                if "error" in answer:
                    rows.append({"case": case, "count": count, "history": history,
                                 "expected": expected, "error": answer["error"]})
                    continue
                rows.append({"case": case, "count": count, "history": history,
                             "expected": expected, "choice": answer["choice"],
                             "correct": answer["choice"] == expected,
                             "probabilities": answer["probabilities"],
                             "latency_ms": answer["latency_ms"]})
        finally:
            worker.stdin.close()
            if worker.poll() is None:
                worker.terminate()
            worker.wait(timeout=5)
    valid = [row for row in rows if "latency_ms" in row]
    durations = sorted(row["latency_ms"] for row in valid)
    result = {"cases": len(rows), "valid": len(valid), "rejected": len(rows) - len(valid),
              "correct": sum(row["correct"] for row in valid),
              "model_ms_p50": statistics.median(durations),
              "model_ms_p95": durations[int(0.95 * (len(durations) - 1))],
              "wall_seconds_including_load": round(time.perf_counter() - start, 2),
              "peak_worker_rss_mib": round(resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss / 1048576, 1)}
    if args.out:
        args.out.write_text(json.dumps({"summary": result, "rows": rows}, indent=2))
    print(json.dumps(result))


if __name__ == "__main__":
    main()
