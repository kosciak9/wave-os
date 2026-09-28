# Browser-decision runtime packaging spike

Package expression: `packages/browser-decision.nix`. Import with
`pkgs.callPackage ./packages/browser-decision.nix { }` on `aarch64-darwin` (macOS
26). **Exposed as `packages.aarch64-darwin.browser-decision`, an explicit
buildable flake artifact. It is not installed or enabled by default, and normal
evaluation does not download it.**
The integration owner chooses if/where to register the package after a live
comparison. No switch or browser access occurs in this package.

## Build and inspect without editing the flake

From the wave-os task worktree, the following tests the complete package using
the flake's pinned Nixpkgs. Run project commands under `devenv shell --`:

```sh
devenv shell -- nix eval --impure --raw --no-write-lock-file --expr 'let p = import (builtins.getFlake "path:/ABSOLUTE/PATH/TO/TASK-WORKTREE").inputs.nixpkgs { system = "aarch64-darwin"; }; in (p.callPackage ./packages/browser-decision.nix { }).drvPath'
devenv shell -- nix build --dry-run --no-link --impure --no-write-lock-file --expr 'let p = import (builtins.getFlake "path:/ABSOLUTE/PATH/TO/TASK-WORKTREE").inputs.nixpkgs { system = "aarch64-darwin"; }; in p.callPackage ./packages/browser-decision.nix { }'
devenv shell -- nix build --no-link --impure --no-write-lock-file --expr 'let p = import (builtins.getFlake "path:/ABSOLUTE/PATH/TO/TASK-WORKTREE").inputs.nixpkgs { system = "aarch64-darwin"; }; in p.callPackage ./packages/browser-decision.nix { }'
```

`$package/bin/browser-decision kev` and `$package/bin/browser-decision laya`
are separate modes. Run **only one process/model at a time** on a 16-GiB Mac.
Each is a persistent serialized stdio worker with exactly one JSON request and
one JSON response per line; the gateway should start its selected mode lazily,
keep it while needed, impose a per-line timeout, kill/restart on timeout or EOF,
and stop it after an idle period. Do not expose it as a TCP listener.

Kev request (the model scores *joint legal actions*, not a separate target and
operation):

```json
{"state":"Goal: Open Documentation. Candidate elements: [0] Home (link) [1] Documentation (link)","choices":["CLICK [0] Home (link)","CLICK [1] Documentation (link)","DONE","BLOCKED"]}
```

Response: `{"choice":"CLICK [1] ...","probabilities":{"CLICK [0] ...":0.1,"CLICK [1] ...":0.9,...},"latency_ms":...}`.
Probabilities are normalized over **exactly the submitted choices** and remain
unrounded. The API does not generate text. Callers must supply a goal, compact
page observation and every legal action, including DONE/BLOCKED only where
meaningful; it is not a browser policy or a confidence guarantee.

Laya request: `{"mode":"native","state":{...},"questions":{...}}` using
the checkpoint-native `operation`, `click_target`, `type_text_target`, etc.
question shapes (`choice` instructions and a criteria object). Response has
`answers` with per-question probability maps and `latency_ms`. Use the v17s
format: elements in **operation-specific choices** rather than repeated in
the state, page text at most 1200 characters, and `head_max_len_train` 768.
`check_runtime.py` contains a complete offline example. For large candidate
tables, select an intentional shortlist before submitting and report that the
distribution is conditional on the shortlist; splitting/comparing chunks
requires an independently validated policy.

The worker bounds a line to 64 KiB and recovers at the next newline, validates
2–60 distinct Kev choices, state ≤8000 chars/384 Kev state tokens and ≤1024
row tokens; Laya accepts ≤8 questions, ≤80 total options, state/questions
≤8000 chars each and v3 page text ≤1200 chars. Validation errors return
`{"error":"..."}` without killing the process. It sets MLX cache to 256 MiB,
active MLX memory to 2 GiB, and wired limit to 1.5 GiB. These are allocator
limits, **not a process RSS or system-pressure guarantee**; benchmark under
realistic host load. No client-supplied model path, runtime Hub fetch, private
configuration, user credential, or live page is needed.

## Provenance and licensing

The package fetches each model file at a commit-pinned Hugging Face URL with
its SHA256. `convert_model.py` merges the pinned Kev LoRA adapter into its Qwen
base on **MLX CPU**, then 4-bit affine/group64-quantizes the merged model. A
restricted, SHA-pinned ZIP reader accepts exactly the four known contiguous
float32 Torch head tensors, writes standalone MLX safetensors, and never
executes checkpoint pickle globals. Neither Torch, Transformers, PEFT, nor a
Python virtualenv is in the runtime closure. The build output carries a
`provenance.json` with source commits and SHA256s of exported weights/head.
For the pinned macOS-26/MLX-0.32.2 build, the CPU-exported model SHA256 is
`329c5a897a4e64fe9dcc771f35313954a4813bc9723c15ad9d94f809a1272b61`;
head SHA256 is `548d0f29dd826f8db0d914b3bc37ef85b78b04be4b6a623e35acaf86b185df6c`.
These differ from the earlier GPU-quantized temporary experiment: **compare
the actual Nix-built artifact**, not the prior temp checkpoint's scores.

Only eight Qwen3.5 model/cache dependency modules are extracted from Apple's
hash-pinned `mlx-lm` 0.31.3 wheel (MIT license copied into the Nix output).
Laya uses the hash-pinned Apache-2.0 `laya-mlx` 0.2.0 wheel; the independent
original model and Kev/Qwen weights are Apache-2.0. MLX is 0.32.2 because
the repository's Nixpkgs has 0.32.0, below `laya-mlx`'s required version.
The runtime's Kev framing and pointer arithmetic derive from
`jaredpalmer/kev` commit `5920c5fe4ca8e0970ed4209ac2c9b8e18bea5109`
(Apache-2.0); no other upstream application code is vendored.

## Verification and known limits

After building, run `devenv shell -- python3 packages/browser-decision/check_runtime.py "$package/bin/browser-decision"`.
The five static reference probability vectors were captured with the pinned
Torch fp32 pointer head against this **same CPU-quantized backbone**. On an M2
the packaged MLX/NumPy head agreed with Torch to maximum **9.8e-8**, same
five winners; output probabilities summed to 1 and parser error requests were
recovered. Stock Laya returned CLICK/target 2 on the offline navigation case.
Peak observed child RSS was **~1.1 GiB**, with the 256-MiB allocator cache.
For a repeatable **offline** 72-case latency/contract probe, run
`devenv shell -- python3 packages/browser-decision/bench_runtime.py "$package/bin/browser-decision" --out /path/inside/your/own/temp/rows.json`.
On this M2, the actual Nix-built CPU-quantized Kev model answered 60/72
(12 width-24 observations correctly **rejected** as over the trained
384-state-token budget), got **54/60** exact on the accepted authored cases,
and measured **204/338 ms p50/p95**, peak worker RSS **~604 MiB**. This is a
different *accepted population* and quantization route from the older
temporary 72-case results. Prune observations deliberately when over budget;
never silently truncate or count rejected cases as successes.
No live browser success or probability calibration is established. Earlier
offline 72-case experiments are in the separate temporary `REPORT2.md`;
native-format Laya and browser-specific Kev must not be compared as if they
shared one input contract. The production default should follow the separate
held-out live benchmark and safety review, not this packaging spike.
