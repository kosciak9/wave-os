#!/usr/bin/env python3
"""Offline, weight-free token audit of persisted Laya judgment requests."""

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path

from laya_mlx.agent import Agent
from laya_mlx.common import build_prefix, build_sequence, render_options, serialize_state
from laya_mlx.tokenizer import Tokenizer


HERE = Path(__file__).resolve().parent
RESULTS = HERE / "results"


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def sha(data):
    return hashlib.sha256(data).hexdigest()


def fields_touched(state, tokens, kept):
    """Identify lost JSON leaf paths using tokenizer offsets, without exporting values."""
    if not isinstance(state, dict) or kept == len(tokens.ids):
        return []
    text = serialize_state(state)
    decoder = json.JSONDecoder()
    touched = []
    def skip(pos):
        while pos < len(text) and text[pos].isspace():
            pos += 1
        return pos

    def walk(pos, path):
        pos = skip(pos)
        start = pos
        if text[pos] == "{":
            pos = skip(pos + 1)
            while text[pos] != "}":
                key, pos = decoder.raw_decode(text, pos)
                pos = skip(pos)
                assert text[pos] == ":"
                pos = walk(pos + 1, (*path, key))
                pos = skip(pos)
                if text[pos] == ",":
                    pos = skip(pos + 1)
                else:
                    assert text[pos] == "}"
            return pos + 1
        if text[pos] == "[":
            pos = skip(pos + 1)
            index = 0
            while text[pos] != "]":
                pos = walk(pos, (*path, index))
                index += 1
                pos = skip(pos)
                if text[pos] == ",":
                    pos = skip(pos + 1)
                else:
                    assert text[pos] == "]"
            return pos + 1
        _, end = decoder.raw_decode(text, pos)
        if any(left < end and right > start for left, right in tokens.offsets[kept:]):
            touched.append(".".join(map(str, path)))
        return end

    assert walk(0, ()) == len(text)
    return touched


def audit(request, tokenizer, config):
    question = request["questions"]["judgment"]
    state = request["state"]
    internal = Agent._to_internal(question)
    head_limit = config["head_max_len_train"]
    max_len = config["max_len"]
    # This is the installed Laya wrapper's effective config, not the library's defaults.
    assert config.get("head_max_len") == head_limit
    ins = str(internal["ins"]).replace(tokenizer.mask_token, " ")
    instruction_ids = tokenizer("choice question: " + ins, add_special_tokens=False)["input_ids"]
    raw_options = [1 + len(tokenizer(" " + option.replace(tokenizer.mask_token, " "),
                                     add_special_tokens=False)["input_ids"])
                   for option in render_options(internal)]
    capped_options = sum(min(size, 49) for size in raw_options)
    question_text = question["instructions"]["question"]
    assert question_text in internal["ins"]
    prefix, markers = build_prefix(tokenizer, internal, head_limit)
    # Infer the exact kept instruction length from the first option marker.
    kept_instruction = markers[0] - 2
    assert prefix[1:markers[0] - 1] == instruction_ids[:kept_instruction]
    state_text = serialize_state(state).replace(tokenizer.mask_token, " ")
    encoded = tokenizer.backend.encode(state_text, add_special_tokens=False)
    room = max(0, max_len - len(prefix) - 1)
    kept_state = min(len(encoded.ids), room)
    ids, actual_markers = build_sequence(tokenizer, state, internal, max_len, head_limit)
    assert prefix == ids[:len(prefix)] and actual_markers == markers
    assert ids[len(prefix):-1] == encoded.ids[:kept_state]
    assert ids[-1] == tokenizer.sep_token_id
    # Exact question survival is established by the full instruction token prefix,
    # not a substring search in decoded subword tokens.
    return {
        "request_sha256": sha(json.dumps(request, sort_keys=True, ensure_ascii=False,
                                          separators=(",", ":")).encode()),
        "choice_count": len(question["criteria"]),
        "question_chars": len(question_text),
        "instruction_json_chars": len(internal["ins"]),
        "instruction_tokens": len(instruction_ids),
        "instruction_tokens_kept": kept_instruction,
        "instruction_tokens_removed": len(instruction_ids) - kept_instruction,
        "question_fully_retained": kept_instruction == len(instruction_ids),
        "prefix_tokens": len(prefix),
        "option_tokens_unbounded": sum(raw_options),
        "option_tokens_after_48_token_text_cap": capped_options,
        "option_tokens_in_prefix": len(prefix) - 3 - kept_instruction,
        "option_tokens_removed_by_head_budget": capped_options - (len(prefix) - 3 - kept_instruction),
        "state_tokens": len(encoded.ids),
        "state_token_budget": room,
        "state_tokens_kept": kept_state,
        "state_tokens_removed": len(encoded.ids) - kept_state,
        "state_truncated_leaf_paths": fields_touched(state, encoded, kept_state),
        "sequence_tokens": len(ids),
        "untruncated_sequence_tokens": len(prefix) + len(encoded.ids) + 1,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-dir", type=Path, required=True, help="installed local Laya checkpoint; never downloaded")
    parser.add_argument("--output", type=Path, default=RESULTS / "judgment-token-audit-20260930.json")
    parser.add_argument("--matrix", type=Path, default=RESULTS / "judgment-matrix-laya-20260930.json")
    parser.add_argument("--coarse", type=Path, default=RESULTS / "judgment-coarse-laya-20260930.json")
    parser.add_argument("--live", type=Path, help="optional frozen live-replay matrix")
    parser.add_argument("--choice-order", choices=("historical", "aligned"), default="historical")
    args = parser.parse_args()
    if not args.model_dir.is_dir() or args.output.exists() or not args.output.parent.is_dir():
        parser.error("local checkpoint must exist and output must be a new file in an existing directory")
    config_bytes = (args.model_dir / "rl_agent_config.json").read_bytes()
    encoder_bytes = (args.model_dir / "encoder/config.json").read_bytes()
    config, encoder = json.loads(config_bytes), json.loads(encoder_bytes)
    if not 4 < config["head_max_len_train"] < config["max_len"] <= encoder["max_position_embeddings"]:
        raise ValueError("checkpoint token budgets invalid")
    tokenizer = Tokenizer(args.model_dir / "tokenizer")
    engine = load_module("judgment_engine_audit", HERE / "judgment-engine.py")
    groups = {}
    matrix_path, coarse_path = args.matrix, args.coarse
    matrix = json.loads(matrix_path.read_text())
    coarse = json.loads(coarse_path.read_text())
    if (matrix["backend"] != "laya" or coarse["backend"] != "laya" or
            matrix.get("choice_order", "historical") != args.choice_order or
            coarse.get("choice_order", "historical") != args.choice_order):
        raise ValueError("expected persisted Laya results")
    sources = [("matrix", matrix), ("coarse", coarse)]
    if args.live:
        live = json.loads(args.live.read_text())
        if live["backend"] != "laya" or live.get("choice_order") != args.choice_order:
            raise ValueError("live replay choice order mismatch")
        sources.append(("live_replay", live))
    for name, source in sources:
        records = {}
        occurrences = 0
        if name != "coarse":
            inputs = ((row["payload"], row["case"], row["question_type"], row["representation"],
                       row["payload_sha256"], row.get("wire_sha256"), row.get("wire_order"), row.get("wire_bytes"))
                      for row in source["rows"])
        elif args.choice_order == "aligned":
            fixture = json.loads((RESULTS / "judgment-coarse-cases-20260929.json").read_text())
            if source["fixture_sha256"] != engine.digest(fixture):
                raise ValueError("aligned coarse fixture mismatch")
            controls = {control["ref"]: control for region in fixture["page"]["regions"] for control in region["controls"]}
            def aligned_inputs():
                for row in source["rows"]:
                    flat = {ref: f'{controls[ref]["role"]} "{controls[ref]["text"]}" in {controls[ref]["context"]}'
                            for ref in row["flat_order"]}
                    flat["INSUFFICIENT"] = "The goal and visible evidence do not uniquely identify a control; do not guess."
                    regions = {name: f"Visible section named {name}. {next(r['description'] for r in fixture['page']['regions'] if r['name'] == name)}"
                               for name in row["region_order"]}
                    regions["INSUFFICIENT"] = flat["INSUFFICIENT"]
                    for stage, item, question, choices in (
                        ("flat", row["flat"]["answer"],
                         "Which visible control uniquely satisfies the goal? Choose INSUFFICIENT if the goal cannot distinguish controls.", flat),
                        ("stage1", row["routed"]["stage1"],
                         "Which visible section contains the unique control satisfying the goal? Choose INSUFFICIENT if the goal cannot distinguish sections.", regions),
                        ("stage2", row["routed"]["stage2"],
                         "Which visible control uniquely satisfies the goal? Choose INSUFFICIENT if the goal cannot distinguish controls.",
                         {label: flat[label] for label in row["routed"]["stage2"]["wire_order"]} if row["routed"]["stage2"] else None)):
                        if item is not None:
                            yield ({"question": question, "choices": choices, "evidence": row["evidence"]},
                                   row["case"], stage, row["permutation"], None,
                                   item["wire_sha256"], item["wire_order"], item["wire_bytes"])
            inputs = aligned_inputs()
        else:
            inputs = (({"question": item["question"], "choices": item["choices"], "evidence": row["evidence"]},
                       row["case"], stage, row["permutation"], None, item["request_sha256_reconstructed"], None, None)
                       for row in source["rows"] for stage, item in
                       (("flat", row["flat"]["request"]), ("stage1", row["routed"]["stage1"]),
                        ("stage2", row["routed"]["stage2"])) if item is not None)
        for payload, case, question_type, representation, payload_hash, expected_request_hash, expected_order, expected_bytes in inputs:
            occurrences += 1
            if payload_hash and engine.digest(payload) != payload_hash:
                raise ValueError("matrix payload hash mismatch")
            wire, metadata = engine.native_wire(payload, "laya", args.choice_order)
            request = json.loads(wire)
            request_hash = sha(wire.encode())
            if expected_request_hash and request_hash != expected_request_hash:
                raise ValueError("recorded wire hash mismatch")
            if expected_order and metadata["wire_order"] != expected_order or expected_bytes and metadata["wire_bytes"] != expected_bytes:
                raise ValueError("recorded wire ordering/length mismatch")
            if request_hash not in records:
                records[request_hash] = {"case": case, "question_type": question_type,
                                         "representation_or_permutation": representation,
                                         **audit(request, tokenizer, config), "wire_sha256": request_hash,
                                         "wire_order": metadata["wire_order"]}
        rows = list(records.values())
        groups[name] = {"persisted_calls": occurrences, "unique_requests": len(rows),
                        "questions_truncated": sum(not r["question_fully_retained"] for r in rows),
                        "states_truncated": sum(r["state_tokens_removed"] > 0 for r in rows),
                        "max_state_tokens_removed": max(r["state_tokens_removed"] for r in rows),
                        "rows": rows}
    result = {"schema_version": 1, "kind": "offline_token_audit_no_weights_or_inference",
              "checkpoint": {"config_sha256": sha(config_bytes), "encoder_config_sha256": sha(encoder_bytes),
                              "encoder_definition_sha256": sha((args.model_dir / "tokenizer/tokenizer.json").read_bytes()),
                             "head_max_len": config["head_max_len"],
                             "head_max_len_train": config["head_max_len_train"],
                             "max_len": config["max_len"],
                             "encoder_max_position_embeddings": encoder["max_position_embeddings"]},
               "choice_order": args.choice_order,
               "sources": {name + "_sha256": sha(path.read_bytes()) for name, path in
                           [("matrix", matrix_path), ("coarse", coarse_path)] +
                           ([("live_replay", args.live)] if args.live else [])},
               "method": "Reconstructed requests using judgment-engine.native_wire, verified recorded wire hashes when present; wire_sha256 is the actual order-sensitive wire fingerprint, request_sha256 is a canonical sorted fingerprint. laya_mlx Agent._to_internal, build_prefix/build_sequence and local checkpoint tokenizer. Historical coarse hashes reconstructed, not captured wire bytes. Counts are per unique request, not inference outcomes.",
              "groups": groups}
    with args.output.open("x", encoding="utf-8") as output:
        json.dump(result, output, ensure_ascii=False, indent=2)
        output.write("\n")
    print(json.dumps({name: {key: group[key] for key in ("persisted_calls", "unique_requests", "questions_truncated", "states_truncated", "max_state_tokens_removed")}
                      for name, group in groups.items()}))


if __name__ == "__main__":
    main()
