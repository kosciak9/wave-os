#!/usr/bin/env python3
"""Bench-only isolated adapter to the installed native runtime; JSON lines on stdout."""

import argparse
import importlib.util
import json
import os
import shlex
import sys
from pathlib import Path


def installed_command(wrapper, backend):
    if not wrapper.is_file():
        raise ValueError("installed browser-decision wrapper unavailable")
    lines = wrapper.read_text(encoding="utf-8").splitlines()
    matching = [line.split("exec ", 1)[1].split(" ;;", 1)[0]
                for line in lines if line.lstrip().startswith(backend + ") exec ")]
    if len(matching) != 1:
        raise ValueError("unrecognized installed wrapper")
    args = shlex.split(matching[0])
    if len(args) != 7 or args[1] != "-I" or args[3:5] != ["--backend", backend] or args[5] != "--model-dir":
        raise ValueError("unrecognized installed runtime command")
    python, _, runtime, _, _, _, model = args
    if not all(Path(p).is_absolute() and Path(p).is_file() for p in (python, runtime)) or not Path(model).is_dir():
        raise ValueError("installed runtime or model unavailable")
    return python, runtime, model


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--backend", choices=("laya", "kev", "kev-browser"), required=True)
    parser.add_argument("--wrapper", type=Path, required=True)
    args = parser.parse_args()
    backend = "kev" if args.backend == "kev-browser" else args.backend
    _, runtime_path, model_path = installed_command(args.wrapper, backend)
    spec = importlib.util.spec_from_file_location("installed_browser_decision", runtime_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.mx.set_cache_limit(256 << 20)
    module.mx.set_memory_limit(2 << 30)
    module.mx.set_wired_limit(1536 << 20)
    model = module.Laya(Path(model_path)) if backend == "laya" else module.Kev(Path(model_path))
    module.mx.set_cache_limit(256 << 20)
    print(json.dumps({"ready": True}), flush=True)
    for line in sys.stdin:
        try:
            request = json.loads(line)
            if not isinstance(request, dict) or len(line.encode()) > module.MAX_LINE:
                raise ValueError("invalid or oversized request")
            if backend == "kev":
                if args.backend == "kev":
                    question = request.pop("question")
                    if not isinstance(question, str) or not question or len(question) > 1000:
                        raise ValueError("invalid typed question")
                    module.INSTRUCTION = question
                state = request.get("state")
                if isinstance(state, str) and len([model.special[0], *model._encode_text(state)]) > module.MAX_STATE:
                    answer = {"error": "representation_limit", "state_tokens": len(model._encode_text(state)) + 1}
                else:
                    answer = model.choose(request)
            else:
                answer = model.choose(request)
        except (ValueError, KeyError, TypeError, OverflowError) as error:
            answer = {"error": str(error)[:200]}
        print(json.dumps(answer, ensure_ascii=False, allow_nan=False), flush=True)


if __name__ == "__main__":
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TOKENIZERS_PARALLELISM"] = "false"
    main()
