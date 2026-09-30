#!/usr/bin/env python3
"""Export a bounded, public judgment fixture from the approved synthetic capture.

Usage: python3 packages/browser-executor/bench/judgment-cases.py INPUT.json [OUTPUT.json]
The input is never copied into the output. Keep the source outside the repository.
The default output is results/judgment-cases-20260929.json next to this file.
"""

import argparse
import copy
import hashlib
import json
import re
from pathlib import Path


LABELS = ("first_form", "first_receipt", "intermediate_receipt", "final_receipt", "branch_choice")
CHOICE = re.compile(r'^CLICK (button|link) "([^"]+)" \(([^)]+)\) \[e\d+\]$')
PAGE = re.compile(r"^(.+?) https?://\S+$")
QUESTIONS = {
    "page_fields_satisfied": "Do all visible required fields have values matching the supplied facts, regardless of whether the form still needs to be submitted?",
    "page_has_more_relevant_work": "Are there still goal-relevant actions available on this page to advance the overall goal, including starting another requested inquiry?",
    "full_goal_complete": "Is the entire requested goal visibly complete now?",
    "candidate_continues_goal": "Does the candidate action safely advance the current goal?",
    "candidate_starts_new_workflow": "Does the candidate action start a separate new inquiry/workflow, whether or not that new workflow is part of the overall goal?",
    "post_action_intended_effect_observed": "Does the after-state show the intended local effect of the candidate action?",
}


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def judgment(expected, basis, calibration="strong"):
    assert expected in ("YES", "NO", "INSUFFICIENT")
    return {"expected": expected, "basis": basis, "calibration": calibration}


def sanitized(record):
    state = record["input"]["state"]
    controls = []
    for choice in record["input"]["choices"]:
        if not choice.startswith("CLICK "):
            continue  # STOP/ESCALATE are caller decisions, not observed page controls.
        match = CHOICE.fullmatch(choice)
        if not match:
            raise ValueError("Unrecognized control syntax; refusing to export")
        role, text, context = match.groups()
        controls.append({"ref": f"c{len(controls) + 1}", "role": role, "text": text, "context": context})
    pages = []
    for page in state["pagesSeen"]:
        match = PAGE.fullmatch(page)
        if not match:
            raise ValueError("Unrecognized page history; refusing to export")
        pages.append(match.group(1))
    return {
        "goal": state["goal"],
        "title": state["title"],
        "text": state["text"],
        "fields": [
            {"ref": f"f{i}", "role": field["type"], "name": field["name"],
             "label": field["label"], "context": field["context"], "value": field["value"]}
            for i, field in enumerate(state["fields"], 1)
        ],
        "required_facts": state["variables"],
        "controls": controls,
        "pages_seen": pages,
        "recent_actions": [action.replace("[ref]", "[local element]") for action in state["recent"]],
    }


def case(id_, evidence, provenance, judgments, candidate=None, transition=None):
    result = {"id": id_, "provenance": provenance, "evidence": evidence,
              "judgments": judgments}
    if candidate is not None:
        result["candidate"] = candidate
    if transition is not None:
        result["transition"] = transition
    result["public_payload_sha256"] = digest(model_payload(result, "raw"))
    return result


def model_payload(item, representation="decision_specific"):
    """The only supported model-facing interface; never pass a whole case to a model.

    raw retains all safe observed evidence; current emulates the old state-only
    projection. decision_specific is a legacy alias for raw, NOT a question-specific
    projection; the caller must implement question-specific filtering separately.
    None of these representations includes provenance, case ID, or judgments.
    """
    evidence = copy.deepcopy(item["evidence"])
    if representation in ("raw", "decision_specific"):
        state = evidence
    elif representation == "current":
        values = "; ".join(f'{f["context"]} / {f["label"]}={f["value"]}' for f in evidence["fields"])
        state = {"page": {"title": evidence["title"], "text": evidence["text"] + "\nCurrent field values: " + values},
                 "pages_seen": evidence["pages_seen"], "recent_actions": evidence["recent_actions"]}
    else:
        raise ValueError("Unknown representation")
    payload = {"state": state}
    if "candidate" in item:
        payload["candidate"] = copy.deepcopy(item["candidate"])
    if "transition" in item:
        payload["transition"] = copy.deepcopy(item["transition"])
    return payload


def export(source):
    records = source["records"]
    if len(records) != len(LABELS) or tuple(r["label"] for r in records) != LABELS:
        raise ValueError("Unexpected frozen capture: refusing to export")
    evidence = {r["label"]: sanitized(r) for r in records}
    original = []
    for record in records:
        label = record["label"]
        e = evidence[label]
        provenance = {"kind": "frozen_synthetic_observation",
                      "private_frame_sha256": digest(record["input"])}
        if label == "first_form":
            questions = {
                "page_fields_satisfied": judgment("YES", "All five visible values match the supplied facts."),
                "page_has_more_relevant_work": judgment("YES", "The filled form has not been submitted."),
                "full_goal_complete": judgment("NO", "No receipt has been observed."),
                "candidate_continues_goal": judgment("YES", "Submitting the filled stage advances the itinerary."),
                "candidate_starts_new_workflow": judgment("NO", "The button submits the current stage."),
            }
            candidate = {"control_ref": "c1"}
        elif label in ("first_receipt", "intermediate_receipt"):
            questions = {
                "page_has_more_relevant_work": judgment("YES", "The receipt explicitly requires the next stage."),
                "full_goal_complete": judgment("NO", "The receipt is not the final receipt."),
                "candidate_continues_goal": judgment("YES", "Continue inquiry advances the existing itinerary."),
                "candidate_starts_new_workflow": judgment("NO", "Continue inquiry is within the current itinerary."),
            }
            candidate = {"control_ref": "c1"}
        elif label == "final_receipt":
            questions = {
                "page_has_more_relevant_work": judgment("NO", "The final receipt records completion of the requested itinerary."),
                "full_goal_complete": judgment("YES", "The final receipt explicitly records the finished inquiry."),
                "candidate_continues_goal": judgment("NO", "Another request does not advance the completed goal."),
                "candidate_starts_new_workflow": judgment("YES", "The link starts another request."),
            }
            candidate = {"control_ref": "c1"}
        else:
            questions = {
                "page_has_more_relevant_work": judgment("YES", "The requested archive must be selected."),
                "full_goal_complete": judgment("NO", "Directory choice precedes the final receipt."),
                "candidate_continues_goal": judgment("YES", "North Pier matches the requested directory."),
                "candidate_starts_new_workflow": judgment("NO", "The choice is part of the current itinerary."),
            }
            candidate = {"control_ref": "c2"}
        original.append(case(label, e, provenance, questions, candidate))

    authored = []

    def perturb(id_, parent, mutate, questions, candidate=None, transition=None):
        e = copy.deepcopy(evidence[parent])
        mutate(e)
        authored.append(case(id_, e, {"kind": "authored_perturbation_not_live", "base_case": parent},
                             questions, candidate, transition))

    perturb("success_but_more", "intermediate_receipt",
            lambda e: e.update(text='"Details receipt 5 of 12" [level=1] | Success! Stage 5 saved. Confirm the remaining stages before the final receipt.'),
            {"page_has_more_relevant_work": judgment("YES", "Remaining stages are explicitly required."),
             "full_goal_complete": judgment("NO", "Success refers only to stage 5."),
             "candidate_continues_goal": judgment("YES", "Continue inquiry advances remaining stages.")},
            {"control_ref": "c1"})
    perturb("neutral_restart", "final_receipt",
            lambda e: e["controls"][0].update(text="Review options"),
            {"full_goal_complete": judgment("YES", "Final receipt remains visible."),
             "candidate_continues_goal": judgment("NO", "No work remains on this goal."),
             "candidate_starts_new_workflow": judgment("INSUFFICIENT", "Review options does not establish the destination of the link.", "exploratory")},
            {"control_ref": "c1"})
    perturb("empty_evidence", "first_receipt",
            lambda e: e.update(title="", text="", pages_seen=[], recent_actions=[], fields=[], controls=[], required_facts={}),
            {"page_has_more_relevant_work": judgment("INSUFFICIENT", "No page evidence survives."),
             "full_goal_complete": judgment("INSUFFICIENT", "No receipt or completion evidence survives.")})
    perturb("missing_preference", "branch_choice",
            lambda e: e.update(goal="Complete the 12-stage archive itinerary and stop after the final receipt.",
                               text='"Choose archive directory" [level=1] | Select an archive directory.'),
            {"full_goal_complete": judgment("NO", "A directory remains to be chosen."),
             "candidate_continues_goal": judgment("INSUFFICIENT", "No requested directory is specified; cannot prefer either option.")},
            {"control_ref": "c2"})
    perturb("wrong_branch", "branch_choice", lambda e: None,
            {"candidate_continues_goal": judgment("NO", "South Pier contradicts the explicit North Pier goal."),
             "candidate_starts_new_workflow": judgment("NO", "It is a wrong branch within the same workflow.")},
            {"control_ref": "c1"})
    perturb("missing_fact", "first_form",
            lambda e: (e["fields"][4].update(value=""), e["required_facts"].pop("destination")),
            {"page_fields_satisfied": judgment("NO", "Destination field is blank."),
             "full_goal_complete": judgment("NO", "No final receipt has been observed."),
             "candidate_continues_goal": judgment("NO", "Submitting with a required field blank is unsupported.")},
            {"control_ref": "c1"})
    perturb("unavailable_fact", "first_form",
            lambda e: (e["fields"][4].update(value=""), e["required_facts"].pop("destination"),
                       e["controls"].clear()),
            {"page_fields_satisfied": judgment("NO", "Destination is blank."),
             "page_has_more_relevant_work": judgment("YES", "The field still requires a value."),
             "full_goal_complete": judgment("NO", "No receipt has been observed.")})
    # These pairs are authored compositions of snapshots, NOT observed adjacent transitions.
    perturb("authored_submit_pair", "first_form", lambda e: None,
            {"post_action_intended_effect_observed": judgment("YES", "The authored after-state says stage 1 details were saved.")},
            {"control_ref": "c1"},
            {"after": copy.deepcopy(evidence["first_receipt"]), "intended_local_effect": "Save stage 1 details."})
    perturb("authored_unchanged_pair", "first_form", lambda e: None,
            {"post_action_intended_effect_observed": judgment("NO", "The authored after-state is unchanged and shows no receipt.")},
            {"control_ref": "c1"},
            {"after": copy.deepcopy(evidence["first_form"]), "intended_local_effect": "Save stage 1 details."})
    def two_inquiries(e):
        e["goal"] = ("Complete two separate 12-stage synthetic archive inquiries. "
                     "Stop only after the final receipt for the second inquiry.")
        e["title"] = "Inquiry receipt 1 of 2"
        e["text"] = ('"Inquiry receipt 1 of 2" [level=1] | The first inquiry is complete. '
                     'Its final synthetic receipt was recorded. The second inquiry has not started yet.')
        e["pages_seen"][-1] = e["title"]
        e["controls"][0]["context"] = e["title"]

    perturb("two_inquiries_first_receipt", "final_receipt", two_inquiries,
            {"page_has_more_relevant_work": judgment("YES", "Start another request is available and a second inquiry is explicitly required."),
             "full_goal_complete": judgment("NO", "Only the first of the two requested inquiries has a receipt."),
             "candidate_continues_goal": judgment("YES", "Starting the requested second inquiry advances the overall goal."),
             "candidate_starts_new_workflow": judgment("YES", "The control starts a separate inquiry, which is also required by the overall goal.")},
            {"control_ref": "c1"})

    cases = original + authored
    for item in cases:
        if not set(item["judgments"]) <= set(QUESTIONS):
            raise ValueError("Unknown question type")
        for representation in ("raw", "current", "decision_specific"):
            payload = canonical(model_payload(item, representation))
            if item["id"].encode() in payload or b'"judgments"' in payload or b'"expected"' in payload:
                raise ValueError("Answer key leaked into model payload")
    return {"schema_version": 1, "questions": QUESTIONS,
            "redactions": ["Dropped source URL, run identifier, tab identifier and native refs; page history retains only titles.",
                                                 "Omitted private terminal flag and native model instructions/answers; local field/control refs start at f1/c1 per case."],
            "cases": cases}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", nargs="?", type=Path,
                        default=Path(__file__).resolve().parent / "results" / "judgment-cases-20260929.json")
    args = parser.parse_args()
    result = export(json.loads(args.input.read_text(encoding="utf-8")))
    contents = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    if args.output.exists():
        if args.output.read_text(encoding="utf-8") != contents:
            parser.error("output already exists with different content; refusing to overwrite")
        return
    args.output.write_text(contents, encoding="utf-8")


if __name__ == "__main__":
    main()
