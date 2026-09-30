"""Offline Laya decision sidecar: one bounded JSON request/response per line."""

import argparse
import json
import os
import sys
import time
from pathlib import Path

os.environ.setdefault("OMP_NUM_THREADS", "4")
os.environ.setdefault("OPENBLAS_NUM_THREADS", "1")
os.environ.setdefault("VECLIB_MAXIMUM_THREADS", "4")

import mlx.core as mx

MAX_LINE = 64 * 1024
MAX_CHOICES = 60
MAX_QUESTIONS = 8
MAX_NATIVE_OPTIONS = 80


def _reject_constant(value):
    raise ValueError(f"non-finite JSON number: {value}")


class Laya:
    def __init__(self, model_dir):
        import laya_mlx

        self.agent = laya_mlx.load(str(model_dir), dtype="float16")

    def choose(self, request):
        if request.get("mode") != "native":
            raise ValueError("Laya requires mode=native, state and native questions")
        state, questions = request.get("state"), request.get("questions")
        if not isinstance(state, (str, dict, list)) or not isinstance(questions, dict):
            raise ValueError("state and questions must be native Laya inputs")
        if not 1 <= len(questions) <= MAX_QUESTIONS or len(json.dumps(state)) > 8000:
            raise ValueError("at most 8 questions and an 8000-character state are supported")
        if isinstance(state, dict) and isinstance(state.get("page"), dict):
            if len(str(state["page"].get("text", ""))) > 1200:
                raise ValueError("native page text must be truncated to v3's 1200 characters")
        if len(json.dumps(questions)) > 8000:
            raise ValueError("native questions exceed the 8000-character budget")
        total_options = 0
        for question in questions.values():
            if not isinstance(question, dict):
                raise ValueError("malformed question")
            criteria = question.get("criteria")
            if question.get("type") == "choice" and (
                not isinstance(criteria, dict) or not 1 <= len(criteria) <= MAX_CHOICES
            ):
                raise ValueError("each choice question needs 1..60 options")
            total_options += len(criteria) if isinstance(criteria, (dict, list)) else 2
        if total_options > MAX_NATIVE_OPTIONS:
            raise ValueError("native questions exceed the 80-option batch budget")
        start = time.perf_counter()
        result = self.agent.predict(state, questions)
        return {"answers": result["answers"], "latency_ms": round((time.perf_counter() - start) * 1000, 2)}


def serve(model_dir, incoming, outgoing):
    if not model_dir.is_absolute() or not model_dir.is_dir():
        raise ValueError("model directory must be an existing absolute path")
    mx.set_cache_limit(256 << 20)
    mx.set_memory_limit(2 << 30)
    mx.set_wired_limit(1536 << 20)
    model = Laya(model_dir)
    mx.set_cache_limit(256 << 20)  # laya-mlx may change the allocator limit at load
    while line := incoming.readline(MAX_LINE + 1):
        if len(line) > MAX_LINE:
            while line and not line.endswith(b"\n"):
                line = incoming.readline(MAX_LINE + 1)
            answer = {"error": "request exceeds 64 KiB"}
        else:
            try:
                request = json.loads(line, parse_constant=_reject_constant)
                if not isinstance(request, dict):
                    raise ValueError("request must be a JSON object")
                answer = model.choose(request)
            except (ValueError, TypeError, KeyError, OverflowError) as exc:
                answer = {"error": str(exc)}
        outgoing.write((json.dumps(answer, ensure_ascii=False, allow_nan=False) + "\n").encode("utf-8"))
        outgoing.flush()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-dir", type=Path, required=True)
    args = parser.parse_args()
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TOKENIZERS_PARALLELISM"] = "false"
    serve(args.model_dir, sys.stdin.buffer, sys.stdout.buffer)


if __name__ == "__main__":
    main()
