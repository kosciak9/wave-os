#!/usr/bin/env python3
"""Bench-only paired formulation study; never modifies the frozen judgments or engine."""

import argparse
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIXTURE = HERE / "results/judgment-cases-20260929.json"
WRAPPER = Path("/nix/store/nqnfs87wqb6bdnljmgpvvrd210lsqdld-browser-decision/bin/browser-decision")
QUESTIONS = {
    "full_goal_complete": {
        "question": "Which state of the ENTIRE user-requested goal is supported by the observed evidence (not merely the current page or stage)?",
        "choices": {
            "GOAL_FINISHED": "The entire requested goal is visibly finished; every requested stage and inquiry is complete.",
            "GOAL_HAS_REMAINING_WORK": "The entire requested goal is not finished; more requested work remains, even if a page or stage reports success.",
            "EVIDENCE_INSUFFICIENT": "The observations do not establish whether the entire requested goal is finished or still has requested work remaining.",
        },
        "labels": {"YES": "GOAL_FINISHED", "NO": "GOAL_HAS_REMAINING_WORK", "INSUFFICIENT": "EVIDENCE_INSUFFICIENT"},
    },
    "candidate_continues_goal": {
        "question": "Which statement about the proposed candidate action and the ENTIRE user-requested goal is supported by the observed evidence?",
        "choices": {
            "ADVANCES_REQUESTED_GOAL": "The candidate safely advances requested work, including a further inquiry only when the user requested it.",
            "DOES_NOT_ADVANCE_REQUESTED_GOAL": "The candidate does not safely advance requested work: it conflicts with supplied facts, submits unfinished work, or starts unrequested work.",
            "EVIDENCE_INSUFFICIENT": "The observations do not establish whether the candidate safely advances the requested goal.",
        },
        "labels": {"YES": "ADVANCES_REQUESTED_GOAL", "NO": "DOES_NOT_ADVANCE_REQUESTED_GOAL", "INSUFFICIENT": "EVIDENCE_INSUFFICIENT"},
    },
}
FORMATS = ("decision_specific_json", "compact_structured_text")
LABEL_ARMS = ("generic", "semantic")


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def compact(case, question_type, engine):
    """Literal, bounded serialization of observation; no answer-derived features."""
    observed = case["evidence"]
    lines = ["Requested goal: " + observed["goal"], "Current page title: " + observed["title"],
             "Current page text: " + observed["text"]]
    lines.append("Visible fields (name; label; current value; supplied fact by name):")
    for field in observed["fields"]:
        fact = observed["required_facts"].get(field["name"])
        lines.append("- " + engine.canonical({"name": field["name"], "label": field["label"],
                     "value": field["value"], "supplied_fact": fact}))
    field_names = {field["name"] for field in observed["fields"]}
    extra_facts = {name: value for name, value in observed["required_facts"].items() if name not in field_names}
    if extra_facts:
        lines.append("Additional supplied facts: " + engine.canonical(extra_facts))
    lines.append("Visible controls (role; text):")
    for control in observed["controls"]:
        lines.append("- " + engine.canonical({"role": control["role"], "text": control["text"]}))
    if question_type == "candidate_continues_goal":
        candidate = engine.candidate_control(case)
        lines.append("Proposed candidate control: " + engine.canonical(
            {"role": candidate["role"], "text": candidate["text"]} if candidate else None))
    lines.append("Previously seen page titles: " + engine.canonical(observed["pages_seen"]))
    lines.append("Recent observed actions: " + engine.canonical(observed["recent_actions"]))
    return {"observation": "\n".join(lines)}


def project(case, question_type, evidence_format, engine):
    if evidence_format == "decision_specific_json":
        return engine.project(case, "decision_specific", question_type)
    if evidence_format == "compact_structured_text":
        return compact(case, question_type, engine)
    raise ValueError("unknown evidence format")


def audit_tokens(requests, backend, wrapper):
    worker = load("judgment_worker_reformulation", HERE / "judgment-worker.py")
    python, _, _ = worker.installed_command(wrapper, backend)
    env = {key: os.environ[key] for key in ("PATH", "HOME", "TMPDIR") if key in os.environ}
    done = subprocess.run([python, "-I", str(Path(__file__).resolve()), "--audit", "--backend", backend,
                           "--executable", str(wrapper)], input=json.dumps(requests, ensure_ascii=False),
                          text=True, capture_output=True, timeout=120, env=env)
    if done.returncode or len(done.stdout) > 400000:
        raise RuntimeError("local_token_audit_failed: " + done.stderr[-300:])
    return json.loads(done.stdout)


def token_audit(backend, wrapper):
    import re
    import tokenizers

    worker = load("judgment_worker_token_audit", HERE / "judgment-worker.py")
    _, _, model = worker.installed_command(wrapper, backend)
    requests = json.load(sys.stdin)
    if backend == "kev":
        tokenizer = tokenizers.Tokenizer.from_file(str(Path(model) / "tokenizer.json"))
        escape = re.compile(r"<\|([A-Za-z0-9_]+)\|>")
        def tokens(text):
            return len(tokenizer.encode(escape.sub(r"<¦\1¦>", text), add_special_tokens=False).ids)
        results = []
        for item in requests:
            state = item["state"]
            choices = item["choices"]
            question = item["question"]
            state_tokens = 1 + tokens(state)
            branch_tokens = 1 + tokens(question) + sum(2 + tokens(f"{i}: {choice}") for i, choice in enumerate(choices)) + 1
            results.append({"state_tokens": state_tokens, "state_limit": 384,
                            "question_tokens": tokens(question), "branch_tokens": branch_tokens,
                            "row_tokens": state_tokens + branch_tokens, "row_limit": 1024,
                            "state_truncated": False, "question_truncated": False})
    else:
        audit = load("judgment_token_audit_reformulation", HERE / "judgment-token-audit.py")
        config = json.loads((Path(model) / "rl_agent_config.json").read_text())
        config["head_max_len"] = config["head_max_len_train"]
        tokenizer = audit.Tokenizer(Path(model) / "tokenizer")
        results = [audit.audit(item, tokenizer, config) for item in requests]
    print(json.dumps(results))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend", choices=("laya", "kev"), required=True)
    parser.add_argument("--executable", type=Path, default=WRAPPER)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--audit", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--preview", action="store_true", help="Audit budgets only; no inference or output file")
    args = parser.parse_args(argv)
    if args.audit:
        token_audit(args.backend, args.executable)
        return
    if not args.preview and (args.output is None or args.output.exists() or not args.output.parent.is_dir()):
        parser.error("--output must be a new file under an existing directory")
    engine = load("judgment_engine_reformulation", HERE / "judgment-engine.py")
    fixture = json.loads(FIXTURE.read_text(encoding="utf-8"))
    fixture_hash = hashlib.sha256(FIXTURE.read_bytes()).hexdigest()
    if fixture_hash != "24019ecb7500dfdb6b223b3bdc4a81864a28949c763ca63a3dc0a2e0552cc4cd":
        parser.error("frozen case file has changed")
    rows = []
    requests = []
    for case in fixture["cases"]:
        for question_type in QUESTIONS:
            if question_type not in case["judgments"]:
                continue
            for evidence_format in FORMATS:
                evidence = project(case, question_type, evidence_format, engine)
                for label_arm in LABEL_ARMS:
                    variant = QUESTIONS[question_type]
                    question = fixture["questions"][question_type] if label_arm == "generic" else variant["question"]
                    choices = engine.LABELS if label_arm == "generic" else variant["choices"]
                    payload = {"question": question, "evidence": evidence, "choices": choices}
                    native = engine.native_request(payload, args.backend)
                    expected = case["judgments"][question_type]["expected"]
                    row = {"case": case["id"], "question_type": question_type,
                           "evidence_format": evidence_format, "label_arm": label_arm,
                           "expected_frozen": expected,
                           "expected_in_arm": expected if label_arm == "generic" else variant["labels"][expected],
                           "expectation_calibration": case["judgments"][question_type]["calibration"],
                           "outcome_source": case["provenance"]["kind"],
                           "payload": payload, "payload_sha256": engine.digest(payload),
                           "native_request_sha256": engine.digest(native),
                           "native_request_bytes": len(engine.canonical(native).encode()),
                           "evidence_bytes": len(engine.canonical(evidence).encode()),
                           "evidence_keys": list(evidence),
                           "projected_info_omitted": (["field refs, roles, repeated contexts", "control refs, repeated contexts", "redundant separately listed supplied facts"]
                               if evidence_format == "compact_structured_text" else
                               ["pages_seen", "recent_actions"] +
                               (["noncandidate controls"] if question_type == "candidate_continues_goal" else [])),
                           "budget_truncated_by_projector": False}
                    rows.append(row)
                    requests.append(native)
    audits = audit_tokens(requests, args.backend, args.executable)
    if len(rows) != len(audits):
        raise ValueError("token audit request count mismatch")
    for row, audit in zip(rows, audits):
        row["tokens"] = audit
    if args.preview:
        from collections import Counter
        print(json.dumps({"requests": len(rows), "state_limits": dict(Counter(
            (row["evidence_format"], row["label_arm"]) for row in rows if
            (args.backend == "kev" and row["tokens"]["state_tokens"] > 384) or
            (args.backend == "laya" and (row["tokens"]["state_tokens_removed"] or
             row["tokens"]["instruction_tokens_removed"] or row["tokens"]["option_tokens_removed_by_head_budget"])))),
            "max_state_tokens": max(row["tokens"]["state_tokens"] for row in rows)}))
        return
    with engine.NativeWorker(args.executable, args.backend) as native_worker:
        worker_ok = True
        for row in rows:
            token = row["tokens"]
            started = time.monotonic()
            try:
                if args.backend == "kev" and (token["state_tokens"] > token["state_limit"] or
                                               token["row_tokens"] > token["row_limit"]):
                    answer = {"error": "representation_limit"}
                elif args.backend == "laya" and (token["state_tokens_removed"] or token["instruction_tokens_removed"] or
                                                 token["option_tokens_removed_by_head_budget"]):
                    answer = {"error": "token_budget_truncation"}
                elif not worker_ok:
                    answer = {"error": "worker_unavailable"}
                else:
                    payload = row["payload"]
                    answer = native_worker.ask(payload["question"], payload["evidence"], payload["choices"])
            except (ValueError, KeyError, RuntimeError, TimeoutError, BrokenPipeError) as exc:
                answer = {"error": type(exc).__name__ + ": " + str(exc)[:120]}
                worker_ok = False
            row.update(answer)
            row["wall_ms"] = round((time.monotonic() - started) * 1000, 2)
    result = {"schema_version": 1, "fixture_sha256": fixture_hash, "backend": args.backend,
              "gate": {"min_top1": 0.5, "min_margin": 0.05},
              "question_types": list(QUESTIONS), "label_arms": list(LABEL_ARMS), "evidence_formats": list(FORMATS),
              "attempted": len(rows), "errors": sum("error" in row for row in rows), "rows": rows,
              "limitations": "Fixture judgments are authored/frozen, not live oracle outcomes. Encodings are semantic, not token-identical; compact retains full page text and facts without truncation. No threshold tuning."}
    with args.output.open("x", encoding="utf-8") as out:
        json.dump(result, out, ensure_ascii=False, indent=2, allow_nan=False)
        out.write("\n")
    print(engine.canonical({"backend": args.backend, "attempted": result["attempted"], "errors": result["errors"]}))


if __name__ == "__main__":
    main()
