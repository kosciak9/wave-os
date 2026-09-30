#!/usr/bin/env python3
"""Compare one-shot and routed native choices on inert, authored directory evidence."""

import argparse
import hashlib
import importlib.util
import json
import random
from pathlib import Path


HERE = Path(__file__).resolve().parent
FIXTURE = HERE / "results/judgment-coarse-cases-20260929.json"
spec = importlib.util.spec_from_file_location("judgment_engine", HERE / "judgment-engine.py")
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)
INSUFFICIENT = "INSUFFICIENT"
INSUFFICIENT_DEFINITION = "The goal and visible evidence do not uniquely identify a control; do not guess."
MEASURED_COARSE_SOURCE_SHA256 = "7de1bbdcdbaa7dae04347bd89f7071d859715b6d636c25ff796918542be07bc3"
CONTROL_QUESTION = "Which visible control uniquely satisfies the goal? Choose INSUFFICIENT if the goal cannot distinguish controls."
REGION_QUESTION = "Which visible section contains the unique control satisfying the goal? Choose INSUFFICIENT if the goal cannot distinguish sections."


def validate(fixture):
    if fixture.get("schema_version") != 1 or fixture.get("provenance") != "authored_synthetic_not_live_browser_state":
        raise ValueError("unsupported or unlabeled fixture")
    regions = fixture["page"]["regions"]
    if len(regions) != 4 or len({r["name"] for r in regions}) != 4 or any(len(r["controls"]) != 5 for r in regions):
        raise ValueError("expected four named regions with five controls each")
    controls = [c for r in regions for c in r["controls"]]
    refs = [c["ref"] for c in controls]
    if len(set(refs)) != 20 or any(c["text"] != "Open details" or not c["context"].startswith(r["name"] + " / ")
                                   for r in regions for c in r["controls"]):
        raise ValueError("invalid stable refs or ambiguous control context")
    if len({c["id"] for c in fixture["cases"]}) != len(fixture["cases"]) or any(
            c["expected"] not in (*refs, INSUFFICIENT) for c in fixture["cases"]):
        raise ValueError("invalid case expectation")


def orders(regions, name):
    pairs = [(r, c) for r in regions for c in r["controls"]]
    if name == "reverse":
        pairs.reverse()
    elif name == "seeded_29":
        random.Random(20260929).shuffle(pairs)
    return pairs


def region_for(regions, ref):
    return next((r["name"] for r in regions if any(c["ref"] == ref for c in r["controls"])), None)


def brier(answer, expected):
    if not answer or not isinstance(answer.get("probabilities"), dict) or expected is None:
        return None
    return round(sum((p - (label == expected)) ** 2 for label, p in answer["probabilities"].items()), 8)


def baseline(goal, pairs):
    # Exact text in the explicit goal and exact region name only; no synonyms or answer key.
    matches = [c["ref"] for r, c in pairs if r["name"] in goal and
               c["context"].split(" / ", 1)[1] in goal]
    return matches[0] if len(matches) == 1 else INSUFFICIENT


def wire_position(answer, label):
    return answer["wire_order"].index(label) if answer and label in answer.get("wire_order", []) else None


def source_hashes():
    return {name: hashlib.sha256((HERE / name).read_bytes()).hexdigest()
            for name in ("judgment-coarse.py", "judgment-engine.py", "judgment-worker.py")}


def audit_aligned(fixture):
    """Check the hosted ordered payload against measured aligned native requests before payment."""
    references = [json.loads((HERE / f"results/judgment-coarse-{backend}-aligned-20260930.json").read_text())
                  for backend in ("laya", "kev")]
    if any(ref["fixture_sha256"] != engine.digest(fixture) or ref["choice_order"] != "aligned" or
           len(ref["rows"]) != 12 for ref in references):
        raise ValueError("aligned native reference or fixture mismatch")
    for case in fixture["cases"]:
        for permutation in ("identity", "reverse", "seeded_29"):
            rows = [next((r for r in reference["rows"] if r["case"] == case["id"] and
                          r["permutation"] == permutation), None) for reference in references]
            if any(row is None for row in rows):
                raise ValueError("missing aligned native reference")
            pairs = orders(fixture["page"]["regions"], permutation)
            region_names = list(dict.fromkeys(r["name"] for r, _ in pairs))
            evidence = {"goal": case["goal"], "page": fixture["page"]["title"],
                        "regions": [{"name": name, "description": next(r["description"] for r in fixture["page"]["regions"] if r["name"] == name)}
                                    for name in region_names],
                        "controls": [f'{c["ref"]}: {c["text"]} | {c["context"]}' for _, c in pairs]}
            flat = {c["ref"]: f'{c["role"]} "{c["text"]}" in {c["context"]}' for _, c in pairs}
            flat[INSUFFICIENT] = INSUFFICIENT_DEFINITION
            regions = {name: f"Visible section named {name}. {next(r['description'] for r in fixture['page']['regions'] if r['name'] == name)}"
                       for name in region_names}
            regions[INSUFFICIENT] = INSUFFICIENT_DEFINITION
            for row in rows:
                if row["evidence"] != evidence:
                    raise ValueError("aligned native evidence mismatch")
                stages = [(CONTROL_QUESTION, flat, row["flat"]["answer"]),
                          (REGION_QUESTION, regions, row["routed"]["stage1"])]
                second = row["routed"]["stage2"]
                if second is not None:
                    subset = {c["ref"]: flat[c["ref"]] for r, c in pairs
                              if r["name"] == row["routed"]["selected_region"]}
                    subset[INSUFFICIENT] = INSUFFICIENT_DEFINITION
                    stages.append((CONTROL_QUESTION, subset, second))
                for question, choices, answer in stages:
                    ordered_hash = engine.digest({"question": question, "evidence": evidence,
                        "choices_ordered": [[key, value] for key, value in choices.items()]})
                    if answer["wire_order"] != list(choices) or answer["model_payload_ordered_hash"] != ordered_hash:
                        raise ValueError("hosted choices do not match aligned native payload")


def run_case(worker, page, case, permutation):
    hosted = worker is None
    def ask(question, evidence, choices):
        return (engine.hosted_ask(question, evidence, choices, choice_order="aligned") if hosted else
                worker.ask(question, evidence, choices))
    pairs = orders(page["regions"], permutation)
    goal = case["goal"]
    flat_controls = [c for _, c in pairs]
    region_names = list(dict.fromkeys(r["name"] for r, _ in pairs))
    region_choices = {name: f"Visible section named {name}. {next(r['description'] for r in page['regions'] if r['name'] == name)}"
                      for name in region_names}
    region_choices[INSUFFICIENT] = INSUFFICIENT_DEFINITION
    evidence = {"goal": goal, "page": page["title"],
                "regions": [{"name": name, "description": next(r["description"] for r in page["regions"] if r["name"] == name)}
                            for name in region_names],
                "controls": [f'{c["ref"]}: {c["text"]} | {c["context"]}' for c in flat_controls]}
    flat_choices = {c["ref"]: f'{c["role"]} "{c["text"]}" in {c["context"]}' for c in flat_controls}
    flat_choices[INSUFFICIENT] = INSUFFICIENT_DEFINITION
    question = CONTROL_QUESTION
    flat = ask(question, evidence, flat_choices)
    if "error" in flat:
        return {"case": case["id"], "permutation": permutation, "failed_phase": "flat", "error": flat}
    routed_first = ask(REGION_QUESTION, evidence, region_choices)
    if "error" in routed_first:
        return {"case": case["id"], "permutation": permutation, "failed_phase": "region",
                "flat_answer": flat, "error": routed_first}
    expected = case["expected"]
    expected_region = region_for(page["regions"], expected)
    routed_second = None
    selected_region = routed_first.get("choice")
    # Never substitute the gold region. A wrong model route remains wrong even if stage 2 is confident.
    if selected_region in region_names and (hosted or routed_first.get("accepted")):
        subset = [c for r, c in pairs if r["name"] == selected_region]
        second_choices = {c["ref"]: flat_choices[c["ref"]] for c in subset}
        second_choices[INSUFFICIENT] = INSUFFICIENT_DEFINITION
        routed_second = ask(question, evidence, second_choices)
        if "error" in routed_second:
            return {"case": case["id"], "permutation": permutation, "failed_phase": "control",
                    "flat_answer": flat, "region_answer": routed_first, "error": routed_second}
    selected = routed_second.get("choice") if routed_second else (
        INSUFFICIENT if selected_region == INSUFFICIENT else None)
    accepted = None if hosted else (routed_first.get("accepted") and (routed_second is None or routed_second.get("accepted")))
    final = selected if hosted or accepted else None
    flat_choice = flat.get("choice")
    flat_final = flat_choice if hosted or flat.get("accepted") else None
    confidence = None
    if not hosted:
        if routed_second is not None and "probabilities" in routed_second:
            confidence = routed_first["probabilities"][selected_region] * routed_second["probabilities"][selected]
        elif selected_region == INSUFFICIENT:
            confidence = routed_first.get("top1")
    return {
        "case": case["id"], "permutation": permutation, "goal": goal, "expected": expected,
        "correct_flat_position": wire_position(flat, expected),
        "correct_region_position": wire_position(routed_first, expected_region or INSUFFICIENT),
        "correct_region_control_position": next((i for i, c in enumerate([c for r, c in pairs if r["name"] == expected_region])
                                                if c["ref"] == expected), None),
        "correct_stage2_wire_position": wire_position(routed_second, expected),
        "evidence": evidence, "evidence_sha256": engine.digest(evidence),
        "region_order": region_names, "flat_order": [c["ref"] for c in flat_controls],
        "flat": {"answer": flat, "pre_gate": None if hosted else flat_choice, "final": flat_final,
                 "pre_gate_correct": None if hosted else flat_choice == expected, "correct": flat_final == expected,
                 "brier": brier(flat, expected), "native_calls": None if hosted else 1,
                 "admission_rule": "valid_categorical_answer_no_probability_gate" if hosted else "top1_0.5_margin_0.05"},
        "routed": {"stage1": routed_first, "stage2": routed_second, "selected_region": selected_region,
                   "pre_gate": None if hosted else selected, "final": final,
                   "pre_gate_correct": None if hosted else selected == expected,
                   "correct": final == expected and (not hosted or selected_region == (expected_region or INSUFFICIENT)),
                   "native_calls": None if hosted else 1 + (routed_second is not None),
                   "admission_rule": "valid_categorical_answer_no_probability_gate" if hosted else "top1_0.5_margin_0.05",
                   "stage1_brier": brier(routed_first, expected_region or INSUFFICIENT),
                   "stage2_brier": brier(routed_second, expected) if selected_region == expected_region and routed_second else None,
                   "selected_path_confidence": confidence,
                   "confidence_category": "categorical_no_confidence" if hosted else "selected_path_not_full_joint",
                   "full_20_way_top2_margin": None},
        "baseline": {"final": baseline(goal, pairs), "correct": baseline(goal, pairs) == expected}
    }


def export_previous(source, fixture, backend):
    """Allowlist a measured local trace and reconstruct its deterministic request envelopes."""
    if source.get("backend") != backend or source.get("schema_version") != 1 or source.get("fixture_sha256") != engine.digest(fixture):
        raise ValueError("measured run/fixture mismatch")
    expected_pairs = [(case["id"], order) for case in fixture["cases"]
                      for order in ("identity", "reverse", "seeded_29")]
    if [(r["case"], r["permutation"]) for r in source["rows"]] != expected_pairs:
        raise ValueError("missing or reordered measured rows")
    rows = []
    for measured, (case_id, permutation) in zip(source["rows"], expected_pairs):
        case = next(c for c in fixture["cases"] if c["id"] == case_id)
        pairs = orders(fixture["page"]["regions"], permutation)
        controls = [c for _, c in pairs]
        regions = list(dict.fromkeys(r["name"] for r, _ in pairs))
        expected_region = region_for(fixture["page"]["regions"], case["expected"])
        evidence = {"goal": case["goal"], "page": fixture["page"]["title"],
                    "regions": [{"name": name, "description": next(r["description"] for r in fixture["page"]["regions"] if r["name"] == name)}
                                for name in regions],
                    "controls": [f'{c["ref"]}: {c["text"]} | {c["context"]}' for c in controls]}
        if (measured["evidence"] != evidence or measured["evidence_sha256"] != engine.digest(evidence)
                or measured["expected"] != case["expected"]
                or measured["flat_order"] != [c["ref"] for c in controls]
                or measured["region_order"] != regions
                or measured["correct_flat_position"] != next((i for i, c in enumerate(controls) if c["ref"] == case["expected"]), None)
                or measured["correct_region_position"] != (regions.index(expected_region) if expected_region else None)
                or measured["baseline"]["final"] != baseline(case["goal"], pairs)):
            raise ValueError("measured evidence, order or expectation mismatch")
        flat = {c["ref"]: f'{c["role"]} "{c["text"]}" in {c["context"]}' for c in controls}
        flat[INSUFFICIENT] = INSUFFICIENT_DEFINITION
        region_choices = {name: f"Visible section named {name}. {next(r['description'] for r in fixture['page']['regions'] if r['name'] == name)}"
                          for name in regions}
        region_choices[INSUFFICIENT] = INSUFFICIENT_DEFINITION
        selected = measured["routed"]["selected_region"]
        second = ({c["ref"]: flat[c["ref"]] for r, c in pairs if r["name"] == selected}
                  if selected in regions and measured["routed"]["stage2"] is not None else None)
        if second is not None:
            second[INSUFFICIENT] = INSUFFICIENT_DEFINITION
        if (measured["routed"]["stage1"].get("choice") != selected or
                (second is not None) != (measured["routed"]["stage2"] is not None) or
                (second is not None and not measured["routed"]["stage1"].get("accepted"))):
            raise ValueError("measured route inconsistent")
        def question_record(question, choices, answer):
            if answer is None:
                return None
            if "error" in answer:
                raise ValueError("measured native error; not a complete distribution")
            if set(answer["probabilities"]) != set(choices):
                raise ValueError("measured probability label mismatch")
            checked = engine.validated(answer["probabilities"], choices)
            if any(answer[key] != checked[key] for key in ("choice", "top1", "top2", "margin", "accepted")):
                raise ValueError("measured answer inconsistent with distribution or historical gate")
            payload = {"question": question, "choices": choices, "evidence": evidence}
            request = engine.native_request(payload, backend)
            return {"question": question, "choices": choices,
                    "request_sha256_reconstructed": hashlib.sha256(engine.canonical(request).encode()).hexdigest(),
                    "answer": answer}
        rows.append({"case": case_id, "permutation": permutation, "goal": case["goal"],
                     "expected": case["expected"], "basis": case["basis"],
                     "positions": {key: measured[key] for key in ("correct_flat_position", "correct_region_position",
                                                              "correct_region_control_position")},
                     "evidence": evidence, "evidence_sha256": measured["evidence_sha256"],
                     "flat": {**{key: measured["flat"][key] for key in ("pre_gate", "final", "pre_gate_correct",
                                                                       "correct", "brier", "native_calls")},
                              "request": question_record(CONTROL_QUESTION, flat, measured["flat"]["answer"])},
                     "routed": {**{key: measured["routed"][key] for key in ("selected_region", "pre_gate", "final",
                                                                           "pre_gate_correct", "correct", "native_calls",
                                                                           "stage1_brier", "stage2_brier",
                                                                           "selected_path_confidence", "confidence_category",
                                                                           "full_20_way_top2_margin")},
                                "stage1": question_record(REGION_QUESTION, region_choices, measured["routed"]["stage1"]),
                                "stage2": question_record(CONTROL_QUESTION, second, measured["routed"]["stage2"])},
                     "baseline": measured["baseline"]})
    return {"schema_version": 1, "provenance": "authored_synthetic_not_live_browser_state",
            "backend": backend, "fixture_sha256": source["fixture_sha256"],
            "measured_coarse_source_sha256": MEASURED_COARSE_SOURCE_SHA256,
            "measured_engine_source_sha256": None,
            "hash_note": "Native request hashes reconstructed from measured evidence, source questions/choices and engine canonical serialization; raw request bytes were not stored. Engine source hash at measurement was not recorded; subsequent latency-only change means current engine hash is not a measurement hash.",
            "gate": {"top1_min": 0.5, "margin_min": 0.05},
            "calibration_note": "Brier scores are per asked categorical question only. Stage 2 is observed only after an accepted model-selected region; selected-path confidence is not a normalized 20-way joint distribution.",
            "native_calls": source["native_calls"], "rows": rows}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend", choices=("laya", "kev", "luna"), required=True)
    parser.add_argument("--executable", type=Path, default=engine.DEFAULT_WRAPPER)
    parser.add_argument("--choice-order", choices=("historical", "aligned"), default="historical")
    parser.add_argument("--cases-json", type=Path, default=FIXTURE)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--export-from", type=Path, help="Export validated authored local measurements without model calls")
    parser.add_argument("--preview", action="store_true", help="Validate only; no native model calls or file writes")
    args = parser.parse_args(argv)
    fixture = json.loads(args.cases_json.read_text())
    validate(fixture)
    if args.backend == "luna" and args.choice_order != "aligned":
        parser.error("luna requires --choice-order aligned to preserve the permutation on the wire")
    if args.backend == "luna":
        if len(fixture["cases"]) != 4:
            parser.error("hosted cap requires exactly four authored cases (at most 36 calls)")
        audit_aligned(fixture)
    if args.output.exists() or not args.output.parent.is_dir():
        parser.error("output must be a new file in an existing directory")
    if args.export_from:
        if args.choice_order != "historical":
            parser.error("--export-from only supports historical measured data")
        result = export_previous(json.loads(args.export_from.read_text()), fixture, args.backend)
        with args.output.open("x", encoding="utf-8") as stream:
            json.dump(result, stream, indent=2, ensure_ascii=False, allow_nan=False)
            stream.write("\n")
        print(json.dumps({"backend": args.backend, "exported_rows": len(result["rows"]),
                          "native_calls": 0}))
        return
    if args.preview:
        print(json.dumps({"cases": [c["id"] for c in fixture["cases"]], "permutations": 3,
                          "flat_controls": 20, "max_calls": 3 * len(fixture["cases"]) * 3,
                          "backend": args.backend, "choice_order": args.choice_order}))
        return
    rows = []
    hashes_start = source_hashes()
    def run(worker):
        for case in fixture["cases"]:
            for permutation in ("identity", "reverse", "seeded_29"):
                row = run_case(worker, fixture["page"], case, permutation)
                rows.append(row)
                if "error" in row:
                    return
    if args.backend == "luna":
        run(None)
    else:
        with engine.NativeWorker(args.executable, args.backend, choice_order=args.choice_order) as worker:
            run(worker)
    hashes_end = source_hashes()
    hosted = args.backend == "luna"
    answers = ([answer for row in rows for answer in (
        [row.get("flat_answer"), row.get("region_answer"), row["error"]] if "error" in row else
        [row["flat"]["answer"], row["routed"]["stage1"], row["routed"]["stage2"]])
        if answer is not None] if hosted else [])
    usage = [answer.get("usage") for answer in answers]
    costs = [u.get("cost_usd") if isinstance(u, dict) else None for u in usage]
    result = {"schema_version": 1, "fixture_sha256": engine.digest(fixture), "backend": args.backend,
              "choice_order": args.choice_order, "source_sha256_start": hashes_start,
              "source_sha256_end": hashes_end, "source_unchanged_during_run": hashes_start == hashes_end,
              "notes": "Inert authored evidence, not a live browser state. Historical Laya sorted criteria on the wire; aligned preserves the offered choice order. Returned wire_order and wire_sha256 describe the actual request sent. Native routed stage 2 uses only the accepted model-selected region; native routed pre_gate is before the final gate but after the stage-1 gate. Luna has categorical answers without probabilities or threshold gates; stage 2 follows any valid selected region, not the ground-truth region. A wrong region followed by INSUFFICIENT does not rescue the route on an ambiguous case. Stage-2 Brier is conditional on being asked with its true label in the choices; no Brier is computed for Luna. Selected-path product is not a normalized 20-way distribution.",
              "gate": None if hosted else {"top1_min": 0.5, "margin_min": 0.05},
              "admission_rule": "valid_categorical_answer_no_probability_gate" if hosted else "top1_0.5_margin_0.05",
              "rows": rows, "native_calls": None if hosted else {arm: sum(row[arm]["native_calls"] for row in rows if "error" not in row)
                                                           for arm in ("flat", "routed")},
              "hosted_calls": len(answers) if hosted else None,
              "max_hosted_calls": 36 if hosted else None,
              "usage": {"known_cost_usd": sum(cost for cost in costs if cost is not None) if any(cost is not None for cost in costs) else None,
                        "cost_complete": bool(costs) and all(cost is not None for cost in costs),
                        "prompt_tokens": sum(u["prompt_tokens"] for u in usage if isinstance(u, dict) and u.get("prompt_tokens") is not None),
                        "completion_tokens": sum(u["completion_tokens"] for u in usage if isinstance(u, dict) and u.get("completion_tokens") is not None),
                        "usage_complete": bool(usage) and all(isinstance(u, dict) and u.get("prompt_tokens") is not None and
                                                              u.get("completion_tokens") is not None for u in usage)} if hosted else None,
              "stopped_on_error": bool(rows and "error" in rows[-1])}
    with args.output.open("x", encoding="utf-8") as stream:
        json.dump(result, stream, indent=2, ensure_ascii=False, allow_nan=False)
        stream.write("\n")
    print(json.dumps({"backend": args.backend, "rows": len(rows), "native_calls": result["native_calls"],
                      "hosted_calls": result["hosted_calls"], "stopped_on_error": result["stopped_on_error"],
                      "source_sha256_start": hashes_start, "source_sha256_end": hashes_end,
                      "accuracy": {arm: sum(row[arm]["correct"] for row in rows if "error" not in row)
                                   for arm in ("flat", "routed")}}))


if __name__ == "__main__":
    main()
