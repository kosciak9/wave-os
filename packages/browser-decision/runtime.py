"""Offline, single-process decision sidecar. Protocol: one bounded JSON request/response per line.

Kev's input framing and pointer head follow jaredpalmer/kev (Apache-2.0), commit
5920c5fe4ca8e0970ed4209ac2c9b8e18bea5109. Only its one-question, hybrid
Qwen3.5 inference path is needed. The backbone is handled by mlx-lm; no PyTorch,
Transformers, PEFT, model hub access, or dynamically loaded model Python code.
"""

import argparse
import json
import math
import os
import re
import sys
import time
from pathlib import Path

os.environ.setdefault("OMP_NUM_THREADS", "4")
os.environ.setdefault("OPENBLAS_NUM_THREADS", "1")
os.environ.setdefault("VECLIB_MAXIMUM_THREADS", "4")

import mlx.core as mx
import numpy as np

MAX_LINE = 64 * 1024
MAX_STATE = 384  # Including the <state> token; checkpoint's training limit.
MAX_ROW = 1024
MAX_CHOICES = 60
MAX_QUESTIONS = 8
MAX_NATIVE_OPTIONS = 80
SPECIAL = ("<|fim_prefix|>", "<|fim_middle|>", "<|box_start|>", "<|box_end|>", "<|fim_suffix|>")
FAKE_SPECIAL = re.compile(r"<\|([A-Za-z0-9_]+)\|>")
INSTRUCTION = (
    "Which single next legal browser action advances the entire goal? DONE only if "
    "visibly satisfied; BLOCKED only if no available control can progress."
)


def _choice_request(request):
    state = request.get("state")
    choices = request.get("choices")
    if not isinstance(state, str) or not state or len(state) > 8000:
        raise ValueError("state must be a nonempty string of at most 8000 characters")
    if (
        not isinstance(choices, list)
        or not 2 <= len(choices) <= MAX_CHOICES
        or any(not isinstance(choice, str) or not choice or len(choice) > 256 for choice in choices)
        or len(set(choices)) != len(choices)
    ):
        raise ValueError("choices must be 2..60 unique nonempty strings of at most 256 characters")
    return state, choices


def _reject_constant(value):
    raise ValueError(f"non-finite JSON number: {value}")


class Kev:
    def __init__(self, model_dir):
        from mlx_lm.models.cache import make_prompt_cache
        from mlx_lm.models.qwen3_5 import Model, ModelArgs
        from tokenizers import Tokenizer

        self._make_cache = make_prompt_cache
        self.tokenizer = Tokenizer.from_file(str(model_dir / "tokenizer.json"))
        self.special = [self.tokenizer.token_to_id(token) for token in SPECIAL]
        if any(token is None for token in self.special):
            raise ValueError("Kev tokenizer lacks one of the checkpoint's five delimiters")
        with (model_dir / "config.json").open(encoding="utf-8") as file:
            config = json.load(file)
        if config.get("model_file") or config.get("model_type") != "qwen3_5":
            raise ValueError("unsupported or custom model architecture")
        if config.get("quantization") != {"group_size": 64, "bits": 4, "mode": "affine"}:
            raise ValueError("expected merged 4-bit checkpoint")
        self.lm = Model(ModelArgs.from_dict(config))
        weights = mx.load(str(model_dir / "model.safetensors"))
        import mlx.nn as nn

        nn.quantize(
            self.lm, group_size=64, bits=4, mode="affine",
            class_predicate=lambda name, module: f"{name}.scales" in weights,
        )
        self.lm.eval()
        self.lm.load_weights(list(weights.items()), strict=True)
        mx.eval(self.lm.parameters())
        self.text = self.lm.language_model.model
        weights = mx.load(str(model_dir / "head.safetensors"))
        self.head = {key: np.asarray(value.astype(mx.float32)) for key, value in weights.items()}
        width = config["text_config"]["hidden_size"]
        if any(self.head[key].shape != shape for key, shape in {
            "q.weight": (256, width), "k.weight": (256, width),
            "q.bias": (256,), "k.bias": (256,),
        }.items()):
            raise ValueError("pointer head dimensions do not match the backbone")
        with (model_dir / "temperature.json").open(encoding="utf-8") as file:
            self.temperature = float(json.load(file)["temperature"])
        if not math.isfinite(self.temperature) or self.temperature <= 0:
            raise ValueError("invalid calibration temperature")

    def _encode_text(self, text):
        # Same user-token escaping and add_special_tokens=False as Kev's pinned encoder.
        return self.tokenizer.encode(FAKE_SPECIAL.sub(r"<¦\1¦>", text), add_special_tokens=False).ids

    def choose(self, request):
        state, choices = _choice_request(request)
        state_ids = [self.special[0], *self._encode_text(state)]
        if len(state_ids) > MAX_STATE:
            raise ValueError("state exceeds the checkpoint's 384-token training limit")
        branch = [self.special[1], *self._encode_text(INSTRUCTION)]
        markers = []
        for index, choice in enumerate(choices):
            branch.extend((self.special[2], *self._encode_text(f"{index}: {choice}"), self.special[3]))
            markers.append(len(branch) - 1)
        branch.append(self.special[4])
        if len(state_ids) + len(branch) > MAX_ROW:
            raise ValueError("choices exceed the checkpoint's 1024-token row limit")

        start = time.perf_counter()
        cache = self._make_cache(self.lm)
        self.text(mx.array([state_ids], dtype=mx.int32), cache=cache)
        # merge copies cache state; a question must not mutate the reusable prefix.
        branch_cache = [type(entry).merge([entry]) for entry in cache]
        h = self.text(mx.array([branch], dtype=mx.int32), cache=branch_cache)
        mx.eval(h)
        # The original Kev pointer head is fp32 torch Linear + dot. Run the tiny
        # readout on CPU NumPy to preserve fp32 behavior without a torch runtime.
        picked = np.asarray(h[0, [*markers, len(branch) - 1]].astype(mx.float32))
        q = self.head["q.weight"] @ picked[-1] + self.head["q.bias"]
        k = picked[:-1] @ self.head["k.weight"].T + self.head["k.bias"]
        logits = (k @ q) * (1 / math.sqrt(q.shape[0])) / self.temperature
        exp = np.exp(logits.astype(np.float64) - float(np.max(logits)))
        probabilities = exp / exp.sum()
        ms = (time.perf_counter() - start) * 1000
        return {
            "choice": choices[int(np.argmax(probabilities))],
            "probabilities": {choice: float(p) for choice, p in zip(choices, probabilities)},
            "latency_ms": round(ms, 2),
        }


class Laya:
    def __init__(self, model_dir):
        import laya_mlx

        self.agent = laya_mlx.load(str(model_dir), dtype="float16")
        self.agent.cfg["head_max_len"] = self.agent.cfg.get(
            "head_max_len_train", self.agent.cfg["head_max_len"]
        )

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


def serve(backend, model_dir, incoming, outgoing):
    if not model_dir.is_absolute() or not model_dir.is_dir():
        raise ValueError("model directory must be an existing absolute path")
    mx.set_cache_limit(256 << 20)
    mx.set_memory_limit(2 << 30)
    mx.set_wired_limit(1536 << 20)
    model = Kev(model_dir) if backend == "kev" else Laya(model_dir)
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
    parser.add_argument("--backend", choices=("kev", "laya"), required=True)
    parser.add_argument("--model-dir", type=Path, required=True)
    args = parser.parse_args()
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TOKENIZERS_PARALLELISM"] = "false"
    serve(args.backend, args.model_dir, sys.stdin.buffer, sys.stdout.buffer)


if __name__ == "__main__":
    main()
