#!/usr/bin/env python3
"""Offline, descriptive analysis of public synthetic judgment runs; never calls a model."""

import argparse
from collections import Counter, defaultdict
import hashlib
import json
import math
from pathlib import Path


HERE = Path(__file__).resolve().parent
RESULTS = HERE / "results"
MATRIX = {
    "laya": "judgment-matrix-laya-20260930.json",
    "kev": "judgment-matrix-kev-20260930.json",
    "kev-browser": "judgment-matrix-kev-browser-control-20260930.json",
}
COARSE = {b: f"judgment-coarse-{b}-20260930.json" for b in ("laya", "kev")}
EPS = 1e-12


def load(path, hashes):
    raw = path.read_bytes()
    hashes[path.name] = hashlib.sha256(raw).hexdigest()
    return json.loads(raw)


def hash_records(hashes):
    """Keep filename as a value, not a field name that resembles a credential."""
    return [{"file": name, "sha256": digest} for name, digest in sorted(hashes.items())]


def average(values):
    return sum(values) / len(values) if values else None


def metrics(rows):
    """Score only complete distributions; errors count against request coverage, not accuracy."""
    good = [r for r in rows if "error" not in r]
    errors = Counter(r["error"] for r in rows if "error" in r)
    if any("representation_limit" != e and "question_limit" != e for e in errors):
        # Preserve a bounded category without echoing potentially sensitive exception text.
        errors = Counter({"budget_limit": sum(v for k, v in errors.items() if k in ("representation_limit", "question_limit")),
                          "other_error": sum(v for k, v in errors.items() if k not in ("representation_limit", "question_limit"))})
    probs = [r for r in good if r.get("probabilities") is not None]
    gated = [r for r in good if isinstance(r.get("accepted"), bool)]
    for r in probs:
        p = r["probabilities"]
        if set(p) != {"YES", "NO", "INSUFFICIENT"} or not math.isclose(sum(p.values()), 1, abs_tol=.001):
            raise ValueError("invalid categorical distribution")
        if r["choice"] != max(p, key=p.get) or r["accepted"] != (r["top1"] >= .5 and r["margin"] >= .05):
            raise ValueError("choice or fixed gate mismatch")
    bins = []
    for i in range(5):
        selected = [r for r in probs if min(4, int(r["top1"] * 5)) == i]
        bins.append({"interval": f"[{i/5:.1f},{(i+1)/5:.1f}{']' if i == 4 else ')'}",
                     "n": len(selected), "mean_confidence": average([r["top1"] for r in selected]),
                     "accuracy": average([int(r["choice"] == r["expected"]) for r in selected])})
    return {
        "requests": len(rows), "covered": len(good), "coverage": len(good) / len(rows) if rows else None,
        "errors": dict(sorted(errors.items())),
        "pre_gate_correct": sum(r["choice"] == r["expected"] for r in good),
        "pre_gate_accuracy": average([int(r["choice"] == r["expected"]) for r in good]),
        "accepted_correct": sum(r["accepted"] and r["choice"] == r["expected"] for r in gated) if gated else None,
        "accepted_wrong": sum(r["accepted"] and r["choice"] != r["expected"] for r in gated) if gated else None,
        "rejected": sum(not r["accepted"] for r in gated) if gated else None,
        "rejected_correct": sum(not r["accepted"] and r["choice"] == r["expected"] for r in gated) if gated else None,
        "rejected_wrong": sum(not r["accepted"] and r["choice"] != r["expected"] for r in gated) if gated else None,
        "rejection_rate_covered": average([int(not r["accepted"]) for r in gated]),
        "label_confusion_pre_gate": {f"{expected}->{choice}": sum(r["expected"] == expected and r["choice"] == choice for r in good)
                                      for expected in ("YES", "NO", "INSUFFICIENT")
                                      for choice in ("YES", "NO", "INSUFFICIENT")},
        "insufficient_predictions_correct": sum(r["choice"] == "INSUFFICIENT" and r["expected"] == "INSUFFICIENT" for r in good),
        "insufficient_predictions_wrong": sum(r["choice"] == "INSUFFICIENT" and r["expected"] != "INSUFFICIENT" for r in good),
        "expected_insufficient": sum(r["expected"] == "INSUFFICIENT" for r in good),
        "probability_rows": len(probs),
        "mean_confidence": average([r["top1"] for r in probs]),
        "mean_confidence_minus_accuracy": average([r["top1"] - int(r["choice"] == r["expected"]) for r in probs]),
        "mean_top2_margin": average([r["margin"] for r in probs]),
        "mean_normalized_entropy": average([r["entropy_nats"] / math.log(len(r["probabilities"])) for r in probs]),
        "mean_multiclass_brier_0_to_2": average([sum((p - int(k == r["expected"])) ** 2 for k, p in r["probabilities"].items()) for r in probs]),
        "mean_log_loss_clipped_1e_minus_12": average([-math.log(max(EPS, r["probabilities"][r["expected"]])) for r in probs]),
        "fixed_equal_width_confidence_bins": bins if probs else None,
    }


def coarse_summary(source):
    rows = source["rows"]
    result = {"cases": len({r["case"] for r in rows}), "permutations_per_case": 3, "rows": len(rows),
              "native_calls": source["native_calls"], "arms": {}}
    for arm in ("flat", "routed"):
        records = [r[arm] for r in rows]
        result["arms"][arm] = {
            "pre_gate_correct": sum(r["pre_gate_correct"] for r in records),
            "accepted_correct": sum(r["correct"] for r in records),
            "accepted_wrong": sum(r["final"] is not None and not r["correct"] for r in records),
            "rejected": sum(r["final"] is None for r in records),
            "insufficient_correct": sum(r["pre_gate"] == "INSUFFICIENT" and row["expected"] == "INSUFFICIENT" for row, r in zip(rows, records)),
            "insufficient_wrong": sum(r["pre_gate"] == "INSUFFICIENT" and row["expected"] != "INSUFFICIENT" for row, r in zip(rows, records)),
        }
    result["flat_21_label_brier_mean"] = average([r["flat"]["brier"] for r in rows])
    result["routed_stage1_5_label_brier_mean"] = average([r["routed"]["stage1_brier"] for r in rows])
    stage2 = [r["routed"]["stage2_brier"] for r in rows if r["routed"]["stage2_brier"] is not None]
    result["routed_stage2_6_label_brier_when_true_region_selected"] = {"n": len(stage2), "mean": average(stage2)}
    result["note"] = "No cross-space Brier average. Stage 2 is conditional on accepted model-selected region; selected-path product is not a normalized 21-label joint probability."
    return result


def analyze(luna=None, aligned=False):
    hashes = {}
    analysis_source_start = hashlib.sha256((HERE / "judgment-analysis.py").read_bytes()).hexdigest()
    cases = load(RESULTS / "judgment-cases-20260929.json", hashes)
    coarse_fixture = load(RESULTS / "judgment-coarse-cases-20260929.json", hashes)
    fixture = {c["id"]: c for c in cases["cases"]}
    if aligned:
        runs = {backend: load(RESULTS / f"judgment-matrix-{backend}-aligned-20260930.json", hashes)
                for backend in ("laya", "kev", "luna")}
        order_audit = load(RESULTS / "judgment-wire-order-audit-20260930.json", hashes)
        if (order_audit["aligned_intervention"]["laya_result_sha256"] != hashes["judgment-matrix-laya-aligned-20260930.json"] or
                order_audit["aligned_intervention"]["kev_result_sha256"] != hashes["judgment-matrix-kev-aligned-20260930.json"]):
            raise ValueError("aligned wire audit source mismatch")
    else:
        runs = {backend: load(RESULTS / name, hashes) for backend, name in MATRIX.items()}
    if luna and not aligned:
        runs["luna"] = load(luna, hashes)
    out = {"schema_version": 1, "source_sha256": hash_records(hashes),
           "gate_unchanged": {"top1_min": .5, "top2_margin_min": .05},
           "method": "Descriptive pilot; 15 distinct correlated synthetic cases, 45 question/case pairs times three distinct projections (not 135 independent trials). Frozen synthetic observations are not external held-out examples; authored perturbations are not live. No fitted probability calibration or threshold selection. Confidence is model-reported, not an action permit. Errors excluded from accuracy and included in request coverage. Hosted categorical answers have no confidence or gate.",
           "matrix": {}, "matched_kev_instruction_control": [], "coarse": {},
           "primary_choice_order": "aligned_YES_NO_INSUFFICIENT" if aligned else "historical_mixed_order"}
    for backend, source in runs.items():
        if source["backend"] != backend or source["schema_version"] != 1 or source["attempted"] != len(source["rows"]):
            raise ValueError("matrix metadata mismatch")
        if aligned and (source.get("choice_order") != "aligned" or source["requested"] != 135 or
                        source["attempted"] != 135 or len(source["rows"]) != 135):
            raise ValueError("incomplete aligned matrix")
        rows = source["rows"]
        for row in rows:
            c = fixture[row["case"]]
            if (row["expected"] != c["judgments"][row["question_type"]]["expected"] or
                row["outcome_source"] != c["provenance"]["kind"] or
                row["backend"] != backend or row["payload"]["question"] != cases["questions"][row["question_type"]]):
                raise ValueError("matrix/fixture mismatch")
            serialized = json.dumps(row["payload"], sort_keys=True, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode()
            if hashlib.sha256(serialized).hexdigest() != row["payload_sha256"]:
                raise ValueError("payload hash mismatch")
            if aligned and (row.get("choice_order") != "aligned" or row.get("wire_order") != ["YES", "NO", "INSUFFICIENT"] or
                            row.get("budget_truncated") is not False):
                raise ValueError("aligned choice order or budget mismatch")
        groups = defaultdict(list)
        for row in rows:
            groups[(row["question_type"], row["representation"])].append(row)
        out["matrix"][backend] = {
            "requested": source["requested"], "attempted": source["attempted"],
            "distinct_cases": len({r["case"] for r in rows}),
            "distinct_case_questions": len({(r["case"], r["question_type"]) for r in rows}),
            "overall": metrics(rows),
            "by_provenance_kind": {kind: metrics([r for r in rows if r["outcome_source"] == kind]) for kind in sorted({r["outcome_source"] for r in rows})},
            "by_question_type_and_representation": {f"{q}|{rep}": metrics(group) for (q, rep), group in sorted(groups.items())},
            "most_critical_confident_wrong_examples_max_12": [
                {"case": r["case"], "question_type": r["question_type"], "representation": r["representation"],
                 "expected": r["expected"], "choice": r["choice"], "top1": r["top1"],
                 "accepted": r["accepted"], "payload_sha256": r["payload_sha256"]}
                for r in sorted((r for r in rows if "error" not in r and r.get("top1") is not None and
                    r["choice"] != r["expected"] and r["top1"] >= .8),
                    key=lambda r: (r["case"] not in ("final_receipt", "two_inquiries_first_receipt"),
                        r["question_type"] not in ("full_goal_complete", "candidate_continues_goal"),
                        -r["top1"]))[:12]],
        }
        out["matrix"][backend]["confident_wrong_counts"] = {
            str(t): sum("error" not in r and r.get("top1") is not None and r["choice"] != r["expected"] and r["top1"] >= t for r in rows)
            for t in (.8, .9)} if backend != "luna" else None
        if backend == "luna":
            out["matrix"][backend]["by_provenance_question_type_and_representation"] = {
                f"{kind}|{q}|{rep}": metrics([r for r in group if r["outcome_source"] == kind])
                for (q, rep), group in sorted(groups.items())
                for kind in sorted({r["outcome_source"] for r in group})}
            out["matrix"][backend]["disagreements_with_authored_labels"] = [
                {"case": r["case"], "question_type": r["question_type"], "representation": r["representation"],
                 "expected": r["expected"], "choice": r["choice"], "visible_payload_sha256": r["payload_sha256"]}
                for r in rows if "error" not in r and r["choice"] != r["expected"]]
    if not aligned:
        typed = {(r["case"], r["question_type"], r["representation"]): r for r in runs["kev"]["rows"]}
        for r in runs["kev-browser"]["rows"]:
            key = (r["case"], r["question_type"], r["representation"])
            other = typed[key]
            if r["payload_sha256"] != other["payload_sha256"]:
                raise ValueError("control comparison must use identical visible payload")
            out["matched_kev_instruction_control"].append({"case": r["case"], "question_type": r["question_type"],
                 "representation": r["representation"], "payload_sha256": r["payload_sha256"],
                 "typed_choice": other.get("choice"), "browser_instruction_choice": r.get("choice"),
                 "typed_accepted": other.get("accepted"), "browser_instruction_accepted": r.get("accepted")})
        out["kev_instruction_control_note"] = "Same visible payload SHA-256, different actual model question/instruction; compare descriptively, no factorial or causal adjustment. Different representation payload hashes are different projections, not identical wire requests."
    if "luna" in runs:
        matched = {b: {(r["case"], r["question_type"], r["representation"], r["repetition"]): r for r in source["rows"]}
                   for b, source in runs.items() if b in ("luna", "laya", "kev")}
        if any(len(index) != len(runs[b]["rows"]) for b, index in matched.items()):
            raise ValueError("duplicate matrix case/question/projection/repetition")
        counts = defaultdict(Counter)
        for key, hosted in matched["luna"].items():
            for b in ("laya", "kev"):
                native = matched[b][key]
                if hosted["payload_sha256"] != native["payload_sha256"]:
                    raise ValueError("cross-backend visible payload mismatch")
                if "error" not in native and "error" not in hosted:
                    counts[b]["matched_complete"] += 1
                    counts[b]["agree"] += hosted["choice"] == native["choice"]
                    counts[b]["disagree"] += hosted["choice"] != native["choice"]
        out["matched_luna_native"] = {b: dict(sorted(c.items())) for b, c in counts.items()}
        focus = {("final_receipt", "full_goal_complete"), ("final_receipt", "candidate_continues_goal"),
                 ("final_receipt", "page_has_more_relevant_work"),
                 ("two_inquiries_first_receipt", "full_goal_complete"),
                 ("two_inquiries_first_receipt", "candidate_continues_goal"),
                 ("two_inquiries_first_receipt", "candidate_starts_new_workflow"),
                 ("success_but_more", "full_goal_complete"),
                 ("neutral_restart", "candidate_starts_new_workflow")}
        out["matched_critical_judgments"] = [
            {"case": case, "question_type": question, "representation": rep,
             "expected": hosted["expected"], "visible_payload_sha256": hosted["payload_sha256"],
             "choices": {b: matched[b][key].get("choice") for b in ("luna", "laya", "kev")},
             "native_top1": {b: matched[b][key].get("top1") for b in ("laya", "kev")},
             "native_accepted": {b: matched[b][key].get("accepted") for b in ("laya", "kev")},
             "kev_budget_error": matched["kev"][key].get("error") == "representation_limit"}
            for key, hosted in sorted(matched["luna"].items())
            for case, question, rep, _ in [key] if (case, question) in focus]
        out["matched_luna_note"] = "Same question/choices/visible evidence payload SHA-256 across three backends; request wrappers, model instructions/channels and models differ, so differences cannot be attributed to model alone. No Luna probability or gate. Expected labels are pre-authored and not revised based on responses."
    for backend, name in (COARSE if not aligned else {b: f"judgment-coarse-{b}-aligned-20260930.json" for b in COARSE}).items():
        source = load(RESULTS / name, hashes)
        if source["backend"] != backend or source["fixture_sha256"] != hashlib.sha256(json.dumps(coarse_fixture, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()).hexdigest():
            raise ValueError("coarse source/fixture mismatch")
        out["coarse"][backend] = coarse_summary(source)
    if aligned:
        strict_excluded = ("missing_fact", "unavailable_fact")
        for case_id in strict_excluded:
            case = fixture[case_id]
            assert len(case["judgments"]) == 3
            assert not case["evidence"]["fields"][-1]["value"]
            assert "destination" not in case["evidence"]["required_facts"]
        out["posthoc_reference_eligibility_sensitivity"] = {
            "status": "Post-hoc expert metadata eligibility mask, not a relabeling or held-out validation; preserve original full-sample scores.",
            "excluded_case_ids": list(strict_excluded), "reason": "Blank required destination fields with destination removed from required_facts; strict reference metadata missing.",
            "all_judgments_excluded_per_backend": 18,
            "by_backend": {b: {"original": out["matrix"][b]["overall"],
                "remaining": metrics([r for r in run["rows"] if r["case"] not in strict_excluded]),
                "excluded_requests": sum(r["case"] in strict_excluded for r in run["rows"])}
                for b, run in runs.items()}}
        prior = load(RESULTS / MATRIX["laya"], hashes)
        before = {(r["case"], r["question_type"], r["representation"], r["repetition"]): r for r in prior["rows"]}
        changes = []
        for r in runs["laya"]["rows"]:
            key = (r["case"], r["question_type"], r["representation"], r["repetition"])
            old = before[key]
            if old["payload_sha256"] != r["payload_sha256"] or old.get("choice") != r.get("choice"):
                raise ValueError("aligned Laya differs beyond option order or gate")
            if old.get("accepted") != r.get("accepted"):
                changes.append({"case": r["case"], "question_type": r["question_type"],
                    "representation": r["representation"], "expected": r["expected"], "choice": r["choice"],
                    "old_accepted": old.get("accepted"), "aligned_accepted": r.get("accepted")})
        if len(changes) != 7:
            raise ValueError("wire order gate audit mismatch")
        out["aligned_vs_historical_laya"] = {"historical_wire_order": ["INSUFFICIENT", "NO", "YES"],
            "aligned_wire_order": ["YES", "NO", "INSUFFICIENT"], "top_choices_unchanged": 135,
            "gate_changes": changes,
            "note": "Order is an input confound, not evidence that all errors were caused by model quality; old inputs differ on actual wire."}
        live_fixture = load(RESULTS / "judgment-live-cases-20260930.json", hashes)
        live_cases = {c["id"]: c for c in live_fixture["cases"]}
        live = {b: load(RESULTS / f"judgment-live-replay-{b}-aligned-20260930.json", hashes)
                for b in ("laya", "kev", "luna")}
        out["aligned_frozen_live_counterfactual_replay"] = {}
        for b, source in live.items():
            if source.get("choice_order") != "aligned" or len(source["rows"]) != 16 or source["requested"] != 16:
                raise ValueError("incomplete frozen replay")
            for r in source["rows"]:
                if r["expected"] != live_cases[r["case"]]["judgments"][r["question_type"]]["expected"] or r.get("wire_order") != ["YES", "NO", "INSUFFICIENT"]:
                    raise ValueError("frozen replay expectation or wire mismatch")
            out["aligned_frozen_live_counterfactual_replay"][b] = {"metrics": metrics(source["rows"]),
                "disagreements": [{"case": r["case"], "question_type": r["question_type"], "representation": r["representation"],
                    "expected": r["expected"], "choice": r.get("choice"), "accepted": r.get("accepted"),
                    "payload_sha256": r["payload_sha256"]} for r in source["rows"]
                    if "error" not in r and r["choice"] != r["expected"]],
                "errors_by_case_question_representation": [{"case": r["case"], "question_type": r["question_type"],
                    "representation": r["representation"], "category": "representation_limit" if r["error"] == "representation_limit" else "other_error"}
                    for r in source["rows"] if "error" in r]}
        live_index = {b: {(r["case"], r["question_type"], r["representation"]): r for r in s["rows"]} for b, s in live.items()}
        out["aligned_frozen_live_counterfactual_replay"]["matched_payload_hashes"] = sum(
            len({live_index[b][key]["payload_sha256"] for b in live_index}) == 1 for key in live_index["laya"])
        if out["aligned_frozen_live_counterfactual_replay"]["matched_payload_hashes"] != 16:
            raise ValueError("live replay visible inputs differ")
        out["aligned_frozen_live_counterfactual_replay"]["note"] = "Counterfactual replay of observed synthetic transitions, not original live model request envelopes; historical Kev compact pre-inputs differed. 8 question/case pairs x two projections, not 16 independent cases."
        out["aligned_composition"] = {}
        for b in ("laya", "kev"):
            comp = load(RESULTS / f"judgment-composition-{b}-20260930.json", hashes)
            if comp["source_aligned_matrix"]["sha256"] != hashes[f"judgment-matrix-{b}-aligned-20260930.json"] or len(comp["rows"]) != 21:
                raise ValueError("composition source mismatch")
            out["aligned_composition"][b] = {"groups": len(comp["rows"]), "counts": comp["counts"],
                "monolithic_errors": comp["monolithic_errors"], "source_calls_replayed": 63, "monolithic_calls": 21}
        out["aligned_composition"]["note"] = "Offline replay of three gated judgments versus separately measured one-shot choice, not a live autonomous run or a three-question improvement; all composed groups escalate."
        token_audit = load(RESULTS / "judgment-token-audit-20260930.json", hashes)
        if token_audit["sources"]["matrix_sha256"] != hashes["judgment-matrix-laya-20260930.json"] or token_audit["groups"]["matrix"]["states_truncated"] != 2:
            raise ValueError("historical token audit mismatch")
        aligned_tokens = load(RESULTS / "judgment-token-audit-aligned-20260930.json", hashes)
        if (aligned_tokens["sources"]["matrix_sha256"] != hashes["judgment-matrix-laya-aligned-20260930.json"] or
                aligned_tokens["groups"]["matrix"]["states_truncated"] != 2):
            raise ValueError("aligned token audit mismatch")
        out["token_audit_scope_note"] = "Historical and aligned offline Laya token audits each found two truncated matrix states. Neither was used to post-hoc exclude accuracy rows; equal ordered payload hashes alone do not prove equal effective model inputs."
        analysis_source_end = hashlib.sha256((HERE / "judgment-analysis.py").read_bytes()).hexdigest()
        input_hashes_end = {name: hashlib.sha256((RESULTS / name).read_bytes()).hexdigest() for name in hashes}
        if hashes != input_hashes_end or analysis_source_start != analysis_source_end:
            raise ValueError("offline input or analysis source changed during analysis")
        out["offline_analysis_file_audit"] = {"input_sha256_at_read": hash_records(hashes),
            "input_sha256_at_end": hash_records(input_hashes_end),
            "analysis_source_sha256_at_start": analysis_source_start,
            "analysis_source_sha256_at_end": analysis_source_end, "unchanged_during_analysis": True,
            "meaning": "These are snapshots during offline analysis, NOT start/end hashes of any measured model run."}
    out["source_sha256"] = hash_records(hashes)
    return out


def final_composition_summary():
    hashes = {}
    sources = {b: load(RESULTS / f"judgment-composition-{b}-20260930.json", hashes)
               for b in ("laya", "kev", "luna")}
    matrix = load(RESULTS / "judgment-matrix-laya-aligned-20260930.json", hashes)
    luna_matrix = load(RESULTS / "judgment-matrix-luna-aligned-20260930.json", hashes)
    kev_matrix = load(RESULTS / "judgment-matrix-kev-aligned-20260930.json", hashes)
    token_audit = load(RESULTS / "judgment-token-audit-aligned-20260930.json", hashes)
    if any(m.get("choice_order") != "aligned" or len(m["rows"]) != 135
           for m in (matrix, kev_matrix, luna_matrix)):
        raise ValueError("incomplete aligned matrix sources")
    for row_laya, row_kev, row_luna in zip(matrix["rows"], kev_matrix["rows"], luna_matrix["rows"]):
        if (len({r["model_payload_ordered_hash"] for r in (row_laya, row_kev, row_luna)}) != 1 or
                len({r["payload_sha256"] for r in (row_laya, row_kev, row_luna)}) != 1 or
                any(r["wire_order"] != ["YES", "NO", "INSUFFICIENT"] for r in (row_laya, row_kev, row_luna))):
            raise ValueError("ordered aligned input mismatch")
    if (token_audit["sources"]["matrix_sha256"] != hashes["judgment-matrix-laya-aligned-20260930.json"] or
            token_audit["groups"]["matrix"]["states_truncated"] != 2):
        raise ValueError("aligned token retention audit mismatch")
    result = {"schema_version": 1,
              "note": "Luna MONOLITHIC is hosted categorical only; Luna file COMPOSED reuses Laya's three local judgments. No Luna three-question composition was measured or inferred. Offline source hashes are not measurement-time hashes.",
              "arms": {}, "ordered_visible_payload_hashes_matched": 135,
              "aligned_laya_state_truncations": 2,
              "effective_native_encoder_content_verified_equal": False,
              "effective_content_note": "Ordered request payload hashes match for 135 triples. The aligned Laya offline token audit finds two truncated states; equal ordered payload hashes do not establish equal effective model content, and hosted/native instruction channels differ.",
              "source_sha256": hash_records(hashes)}
    for backend, source in sources.items():
        expected_composition = "laya" if backend == "luna" else backend
        measured_matrix = matrix if expected_composition == "laya" else kev_matrix
        if (source.get("composition_backend") != expected_composition or source.get("backend") != backend or
                source["source_aligned_matrix"]["sha256"] != hashes[f"judgment-matrix-{expected_composition}-aligned-20260930.json"] or
                len(measured_matrix["rows"]) != 135 or len(source["rows"]) != 21 or source["requested_groups"] != 21):
            raise ValueError("composition backend, source or group mismatch")
        result["arms"][backend] = {"monolithic_backend": backend, "composed_source_backend": expected_composition,
                "groups": 21, "composed_source_calls_replayed": 63, "monolithic_attempted": source["attempted_monolithic"],
                "monolithic_errors": source["monolithic_errors"], "counts": source["counts"]}
    result["source_sha256"] = hash_records(hashes)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--luna", type=Path, help="Optional existing Luna run; write a NEW comparison artifact with --output")
    parser.add_argument("--aligned", action="store_true", help="Use complete aligned native/hosted matrices, frozen replay and composition")
    parser.add_argument("--final-composition-summary", action="store_true", help="Summarize three measured monolithic arms and the actual composed sources")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists() or not args.output.parent.is_dir():
        parser.error("output must be a new file in an existing directory")
    if args.luna and args.aligned or args.final_composition_summary and (args.luna or args.aligned):
        parser.error("incompatible input modes")
    result = final_composition_summary() if args.final_composition_summary else analyze(args.luna, args.aligned)
    with args.output.open("x", encoding="utf-8") as stream:
        json.dump(result, stream, indent=2, ensure_ascii=False, allow_nan=False)
        stream.write("\n")
    if args.final_composition_summary:
        print(json.dumps({b: {"composed_from": v["composed_source_backend"], "monolithic_correct":
              v["counts"]["monolithic"]["correct_behavior"].get("true", 0)} for b, v in result["arms"].items()}))
    else:
        print(json.dumps({k: {"covered": v["overall"]["covered"], "pre_gate_correct": v["overall"]["pre_gate_correct"],
                             "accepted_wrong": v["overall"]["accepted_wrong"]} for k, v in result["matrix"].items()}))


if __name__ == "__main__":
    main()
