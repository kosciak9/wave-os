"""Nix-build-time conversion of pinned Qwen/adapter weights into a standalone CPU-built MLX model.

Never accesses the Hub. The LoRA is folded into bf16 base weights (fp32 delta),
THEN affine/group64 4-bit quantization, exactly once. The pointer head is
converted separately from a weights-only Torch checkpoint to safetensors.
Derived from the merge arithmetic in Kev's Apache-2.0 mlx_model.py at
5920c5fe4ca8e0970ed4209ac2c9b8e18bea5109.
"""
import argparse
import hashlib
import json
import pickle
import shutil
import zipfile
from collections import OrderedDict
from pathlib import Path

import mlx.core as mx
import mlx.nn as nn
import numpy as np
from mlx.utils import tree_flatten
from mlx_lm.models.qwen3_5 import Model, ModelArgs


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for block in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def read_pinned_head(path):
    """Restricted reader for this SHA-pinned Torch ZIP (four contiguous float32 tensors).

    No torch dependency or arbitrary pickle globals. Reject unfamiliar storage,
    object types, strides, locations, and shapes instead of guessing.
    """
    with zipfile.ZipFile(path) as archive:
        members = archive.namelist()
        data_name = next((name for name in members if name.endswith("/data.pkl")), None)
        if not data_name:
            raise ValueError("pointer head is not a supported Torch ZIP")
        prefix = data_name.removesuffix("data.pkl")
        if archive.read(prefix + "byteorder") != b"little":
            raise ValueError("unsupported pointer head byte order")

        class FloatStorage:
            pass

        def rebuild_tensor(storage, offset, shape, stride, requires_grad, hooks):
            if requires_grad or not isinstance(hooks, OrderedDict) or offset != 0:
                raise ValueError("unsupported tensor view or hooks")
            if len(shape) not in (1, 2) or tuple(stride) != ((1,) if len(shape) == 1 else (shape[1], 1)):
                raise ValueError("noncontiguous pointer head")
            if int(np.prod(shape)) != storage.size:
                raise ValueError("storage size mismatch")
            return storage.reshape(shape)

        class Restricted(pickle.Unpickler):
            def find_class(self, module, name):
                allowed = {
                    ("torch._utils", "_rebuild_tensor_v2"): rebuild_tensor,
                    ("torch", "FloatStorage"): FloatStorage,
                    ("collections", "OrderedDict"): OrderedDict,
                }
                try:
                    return allowed[(module, name)]
                except KeyError as exc:
                    raise ValueError(f"unrecognized pointer head global {module}.{name}") from exc

            def persistent_load(self, descriptor):
                if not isinstance(descriptor, tuple) or len(descriptor) != 5:
                    raise ValueError("unsupported storage descriptor")
                kind, storage_type, key, location, size = descriptor
                if kind != "storage" or storage_type is not FloatStorage or location != "cpu" or not str(key).isdigit():
                    raise ValueError("unsupported storage type or location")
                name = prefix + "data/" + str(key)
                if name not in members or size not in (256, 256 * 1024):
                    raise ValueError("unexpected pointer head storage")
                data = archive.read(name)
                if len(data) != size * 4:
                    raise ValueError("truncated pointer head storage")
                return np.frombuffer(data, dtype="<f4").copy()

        from io import BytesIO

        result = Restricted(BytesIO(archive.read(data_name))).load()
    if not isinstance(result, dict) or result.get("base") != "Qwen/Qwen3.5-0.8B-Base":
        raise ValueError("unexpected pointer head base")
    if set(result["head"]) != {"q.weight", "q.bias", "k.weight", "k.bias"}:
        raise ValueError("unexpected pointer head tensors")
    return result


def convert(base, adapter, output):
    if output.exists():
        raise ValueError("output must not already exist")
    mx.set_default_device(mx.cpu)
    mx.set_cache_limit(256 << 20)
    config = json.loads((base / "config.json").read_text())
    if config.get("model_type") != "qwen3_5" or config.get("model_file"):
        raise ValueError("unsupported or custom base architecture")
    model = Model(ModelArgs.from_dict(config))
    source_weights = {}
    for file in sorted(base.glob("model*.safetensors")):
        source_weights.update(mx.load(str(file)))
    model.eval()
    model.load_weights(list(model.sanitize(source_weights).items()), strict=True)
    mx.eval(model.parameters())
    del source_weights
    weights = mx.load(str(adapter / "adapter_model.safetensors"))
    adapter_config = json.loads((adapter / "adapter_config.json").read_text())
    if adapter_config.get("trainable_token_indices"):
        raise ValueError("unexpected trainable token indices")
    if adapter_config["base_model_name_or_path"] != "Qwen/Qwen3.5-0.8B-Base":
        raise ValueError("unexpected adapter base")
    alpha = adapter_config["lora_alpha"] / (adapter_config["r"] ** 0.5 if adapter_config.get("use_rslora") else adapter_config["r"])
    parameters = dict(tree_flatten(model.parameters()))
    merged = {}
    for name, a in weights.items():
        if not name.endswith(".lora_A.weight"):
            continue
        stem = name[: -len(".lora_A.weight")]
        target = stem.replace("base_model.model.", "language_model.model.", 1) + ".weight"
        if target not in parameters or stem + ".lora_B.weight" not in weights:
            raise ValueError(f"adapter layer not in base: {stem}")
        base_weight = parameters[target]
        delta = (weights[stem + ".lora_B.weight"].astype(mx.float32) @ a.astype(mx.float32)) * alpha
        merged[target] = (base_weight.astype(mx.float32) + delta).astype(base_weight.dtype)
        mx.eval(merged[target])
    if len(merged) != sum(k.endswith(".lora_A.weight") for k in weights):
        raise ValueError("adapter layers were not all merged")
    model.load_weights(list(merged.items()), strict=False)
    mx.eval(model.parameters())
    del merged, parameters, weights
    mx.clear_cache()

    nn.quantize(
        model, group_size=64, bits=4, mode="affine",
        class_predicate=lambda name, module: (
            hasattr(module, "to_quantized") and module.weight.shape[-1] % 64 == 0
        ),
    )
    mx.eval(model.parameters())
    mx.clear_cache()
    output.mkdir(parents=True)
    mx.save_safetensors(str(output / "model.safetensors"), dict(tree_flatten(model.parameters())), metadata={"format": "mlx"})
    config["quantization"] = {"group_size": 64, "bits": 4, "mode": "affine"}
    config["quantization_config"] = config["quantization"]
    (output / "config.json").write_text(json.dumps(config, indent=2) + "\n")
    for filename in ("tokenizer.json", "tokenizer_config.json"):
        shutil.copyfile(base / filename, output / filename)

    head = read_pinned_head(adapter / "head.pt")
    state = head["head"]
    mx.save_safetensors(str(output / "head.safetensors"), {key: mx.array(value) for key, value in state.items()})
    (output / "temperature.json").write_text(json.dumps({"temperature": float(head["temperature"])}) + "\n")
    (output / "provenance.json").write_text(json.dumps({
        "base_commit": "dc7cdfe2ee4154fa7e30f5b51ca41bfa40174e68",
        "adapter_commit": "9a45d25eb2ab761841196625383fa1dff0e56c1e",
        "merge": "fp32 delta added to bf16 base before affine group64 4-bit quantization on MLX CPU",
        "model_sha256": sha256(output / "model.safetensors"),
        "head_sha256": sha256(output / "head.safetensors"),
    }, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", type=Path, required=True)
    parser.add_argument("--adapter", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    convert(args.base, args.adapter, args.output)
