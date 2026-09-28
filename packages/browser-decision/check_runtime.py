"""Run after the targeted Nix build; validates the packaged offline JSONL protocol.

Usage: python check_runtime.py /nix/store/...-browser-decision/bin/browser-decision
The five expected probability vectors were captured from Kev's pinned fp32
PyTorch PointerHead on the very same Nix-built CPU-quantized backbone; this
check needs no PyTorch or model-hub access. Not a browser accuracy test.
"""
import json
import os
import resource
import subprocess
import sys
from pathlib import Path


def invoke(program, backend, records):
    env = {**os.environ, "HF_HUB_OFFLINE": "1", "OMP_NUM_THREADS": "4"}
    result = subprocess.run(
        [program, backend],
        input="".join(json.dumps(record) + "\n" for record in records),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=120,
        check=True,
        env=env,
    )
    answers = [json.loads(line) for line in result.stdout.splitlines()]
    assert len(answers) == len(records), (result.stdout, result.stderr)
    return answers


program = sys.argv[1]
fixtures = json.loads((Path(__file__).parent / "parity-fixtures.json").read_text())
invalid = [
    {"state": "goal", "choices": []},
    {"state": "goal", "choices": ["same", "same"]},
    {"state": "x" * 70000, "choices": ["one", "two"]},
    {"state": "word " * 500, "choices": ["one", "two"]},
    {"state": "goal", "choices": ["one", "two"], "extra": float("nan")},
    {"state": "goal", "choices": ["one", "two"], "x": "extra"},
]
answers = invoke(program, "kev", fixtures + invalid)
worst = 0.0
for case, answer in zip(fixtures, answers):
    scores = list(answer["probabilities"].values())
    assert list(answer["probabilities"]) == case["choices"]
    assert answer["choice"] == case["choices"][max(range(len(scores)), key=scores.__getitem__)]
    assert abs(sum(scores) - 1.0) < 1e-10
    worst = max(worst, max(abs(a - b) for a, b in zip(scores, case["reference_torch"])))
assert worst < 1e-4, f"MLX/Numpy versus Torch pointer parity exceeds budget: {worst}"
assert all("error" in answer for answer in answers[-6:-1]), answers[-6:]
assert "probabilities" in answers[-1]  # Unknown fields don't affect protocol.

native = {
    "mode": "native",
    "state": {"page": {"url": "https://example.invalid", "title": "Docs navigation", "text": "Home | Documentation | Pricing"}, "recent_actions": []},
    "questions": {
        "operation": {"type": "choice", "instructions": {"goal": "Open Documentation", "rules": "Advance the goal; DONE only if visibly satisfied."}, "criteria": {"CLICK": "Click an element or link", "DONE": "Every requirement satisfied", "BLOCKED": "No supported operation can progress"}},
        "click_target": {"type": "choice", "instructions": {"goal": "Open Documentation", "operation": "CLICK", "rules": "Choose the best observed target"}, "criteria": {"1": "[1] Home (link)", "2": "[2] Documentation (link)", "3": "[3] Pricing (link)"}},
    },
}
laya = invoke(program, "laya", [native, {"mode": "native", "state": "x", "questions": {}}])
assert laya[0]["answers"]["operation"]["choice"] == "CLICK", laya
assert laya[0]["answers"]["click_target"]["choice"] == "2", laya
assert "error" in laya[1]
print(json.dumps({"kev_cases": len(fixtures), "max_pointer_probability_error": worst,
                  "laya_operation": laya[0]["answers"]["operation"]["choice"],
                  "laya_target": laya[0]["answers"]["click_target"]["choice"],
                  "max_child_rss_mib": round(resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss / (1024 * 1024), 1)}))
