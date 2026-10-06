"""Offline, process-isolated benchmarking of locally installed ASR models."""

import argparse
import hashlib
import importlib.metadata
import importlib.util
import json
import math
import os
import platform
import resource
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import unicodedata
import uuid
import wave
from datetime import datetime, timezone
from pathlib import Path

from backends import MODEL_SPECS

MODEL_NAMES = tuple(MODEL_SPECS)
DEFAULT_MODELS_DIR = Path.home() / "Library/Caches/ASRBenchmark/models"
DEFAULT_ARCHIVE = Path.home() / "Library/Application Support/Whisper/Recordings"
DEFAULT_OUTPUT = Path.home() / "Library/Application Support/ASRBenchmark/Runs"
LOCAL_PATHS = {name: spec["relative_path"] for name, spec in MODEL_SPECS.items()}
SAMPLE_RATE = 16000
CHUNK_SECONDS = 30
RSS_INTERVAL = 0.020


class BenchmarkInputError(ValueError):
    """An input error whose message is safe to display on the terminal."""


def private_json(path, value):
    with path.open("w", encoding="utf-8") as handle:
        os.chmod(path, 0o600)
        json.dump(value, handle, ensure_ascii=False, indent=2, allow_nan=False)
        handle.write("\n")


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def model_fingerprint(path):
    if path.is_file():
        files = [(path.name, path)]
    elif path.is_dir():
        files = sorted(
            (str(item.relative_to(path)), item)
            for item in path.rglob("*")
            if item.is_file()
        )
    else:
        raise ValueError("Local model path does not exist")
    if not files:
        raise ValueError("Local model directory is empty")
    entries = [
        {"file": name, "bytes": item.stat().st_size, "sha256": sha256(item)}
        for name, item in files
    ]
    canonical = json.dumps(entries, sort_keys=True, separators=(",", ":")).encode()
    return {
        "path": str(path),
        "files": entries,
        "contents_sha256": hashlib.sha256(canonical).hexdigest(),
    }


def words(text):
    normalized = unicodedata.normalize("NFC", text).casefold()
    normalized = "".join(
        char for char in normalized if unicodedata.category(char)[0] not in "PS"
    )
    return normalized.split()


def word_error(reference, hypothesis):
    if reference is None:
        return {"wer": None, "word_errors": None, "reference_words": None}
    expected, actual = words(reference), words(hypothesis)
    previous = list(range(len(actual) + 1))
    for i, token in enumerate(expected, 1):
        current = [i]
        for j, other in enumerate(actual, 1):
            current.append(
                min(current[-1] + 1, previous[j] + 1, previous[j - 1] + (token != other))
            )
        previous = current
    errors = previous[-1]
    return {
        "wer": errors / len(expected) if expected else None,
        "word_errors": errors,
        "reference_words": len(expected),
    }


def discover_clips(root, language, limit):
    clips = []
    ignored = 0
    if not root.is_dir():
        return clips, ignored
    for metadata_path in sorted(root.glob("*/metadata.json")):
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        if not isinstance(metadata, dict):
            raise BenchmarkInputError("Archive metadata must be a JSON object")
        if metadata.get("state") != "completed":
            ignored += 1
            continue
        if metadata.get("schema_version") != 1:
            raise BenchmarkInputError("Unsupported archive schema")
        directory = metadata_path.parent
        name = metadata.get("audio_file")
        if (
            not isinstance(name, str)
            or not name
            or name in (".", "..")
            or Path(name).name != name
            or "/" in name
            or "\\" in name
        ):
            raise BenchmarkInputError("Unsafe archive audio basename")
        audio = directory / name
        if audio.resolve().parent != directory.resolve() or not audio.is_file():
            raise BenchmarkInputError("Archive audio must be a local file within its recording")
        fields = metadata.get("request_fields")
        if not isinstance(fields, dict) or any(
            not isinstance(values, list)
            or any(not isinstance(value, str) for value in values)
            for values in fields.values()
        ):
            raise BenchmarkInputError("Invalid archive request fields")
        archived_language = (fields.get("language") or ["auto"])[0]
        label_path = directory / "language.txt"
        label = label_path.read_text(encoding="utf-8").strip() if label_path.exists() else None
        if label is not None and label not in ("pl", "en"):
            raise BenchmarkInputError("language.txt must contain pl or en")
        selected_language = language or label or archived_language
        if selected_language not in ("auto", "pl", "en"):
            raise BenchmarkInputError("Archive language needs an auto, pl or en override")
        reference_path = directory / "reference.txt"
        reference = (
            reference_path.read_text(encoding="utf-8") if reference_path.exists() else None
        )
        expected_hash = metadata.get("audio_sha256")
        if not isinstance(expected_hash, str) or len(expected_hash) != 64:
            raise BenchmarkInputError("Missing or invalid archived audio SHA256")
        clips.append(
            {
                "clip_id": directory.name,
                "source": str(audio.resolve()),
                "audio_sha256": expected_hash.lower(),
                "language": selected_language,
                "language_source": "cli" if language else "label" if label else "archive",
                "reference": reference,
                "reference_sha256": sha256(reference_path) if reference is not None else None,
            }
        )
        if limit is not None and len(clips) >= limit:
            break
    # Validate the entire selected corpus before subprocesses or output allocation.
    for clip in clips:
        if sha256(Path(clip["source"])) != clip["audio_sha256"]:
            raise BenchmarkInputError("Archived audio SHA256 mismatch; benchmark aborted")
    return clips, ignored


def normalize_clips(clips, temporary, log):
    for index, clip in enumerate(clips):
        started = time.perf_counter()
        normalized = temporary / f"{index:06d}.wav"
        subprocess.run(
            [
                "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                "-i", clip["source"], "-map", "0:a:0", "-vn", "-ar", str(SAMPLE_RATE),
                "-ac", "1", "-c:a", "pcm_s16le", str(normalized),
            ],
            stdin=subprocess.DEVNULL, stdout=log, stderr=log, check=True,
        )
        chunks = []
        with wave.open(str(normalized), "rb") as source:
            if (source.getframerate(), source.getnchannels(), source.getsampwidth()) != (
                SAMPLE_RATE, 1, 2
            ):
                raise ValueError("Unexpected normalized WAV format")
            frames = source.getnframes()
            if frames == 0:
                raise ValueError("Empty normalized audio")
            for offset in range(0, frames, SAMPLE_RATE * CHUNK_SECONDS):
                chunk = temporary / f"{index:06d}-{len(chunks):06d}.wav"
                data = source.readframes(SAMPLE_RATE * CHUNK_SECONDS)
                with wave.open(str(chunk), "wb") as output:
                    output.setnchannels(1)
                    output.setsampwidth(2)
                    output.setframerate(SAMPLE_RATE)
                    output.writeframes(data)
                chunks.append(str(chunk))
        normalized.unlink()
        clip.update(
            chunks=chunks,
            audio_duration_seconds=frames / SAMPLE_RATE,
            normalization_ms=(time.perf_counter() - started) * 1000,
        )


def runtime_versions():
    versions = {}
    for package in ("psutil", "mlx", "mlx-audio", "mlx-lm", "numpy", "transformers", "huggingface-hub"):
        try:
            versions[package] = importlib.metadata.version(package)
        except importlib.metadata.PackageNotFoundError:
            versions[package] = None
    chip = platform.processor() or platform.machine()
    if sys.platform == "darwin":
        result = subprocess.run(
            ["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"],
            capture_output=True, text=True, check=False,
        )
        if result.returncode == 0:
            chip = result.stdout.strip()
    return {
        "python": platform.python_version(), "os": platform.system(),
        "os_release": platform.release(), "macos": platform.mac_ver()[0] or None,
        "architecture": platform.machine(), "chip": chip, "packages": versions,
    }


class ProcessTreeSampler:
    """RSS sums are sampled process accounting, not unified physical allocations."""

    def __init__(self):
        import psutil

        self.psutil = psutil
        self.root = psutil.Process()
        self.peak = 0
        self.samples = 0
        self.cpu_initial = {}
        self.cpu_latest = {}
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.sample_loop, daemon=True)

    def sample(self):
        try:
            processes = [self.root, *self.root.children(recursive=True)]
        except self.psutil.Error:
            processes = [self.root]
        rss = 0
        for process in processes:
            try:
                identity = (process.pid, process.create_time())
                rss += process.memory_info().rss
                cpu = process.cpu_times()
                total = cpu.user + cpu.system
                # Newly observed children started during this sample; count their lifetime CPU.
                self.cpu_initial.setdefault(
                    identity, total if self.samples == 0 or process == self.root else 0.0
                )
                self.cpu_latest[identity] = total
            except self.psutil.Error:
                continue
        self.peak = max(self.peak, rss)
        self.samples += 1

    def sample_loop(self):
        while not self.stop.wait(RSS_INTERVAL):
            self.sample()

    def __enter__(self):
        self.sample()
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.stop.set()
        self.thread.join()
        self.sample()

    def result(self):
        return {
            "sampled_peak_process_tree_rss_bytes": self.peak,
            "rss_sample_count": self.samples,
            "sampled_process_tree_cpu_seconds": sum(
                max(0.0, total - self.cpu_initial[identity])
                for identity, total in self.cpu_latest.items()
            ),
        }


def offline_environment():
    return {
        "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "HF_DATASETS_OFFLINE": "1",
        "HF_HUB_DISABLE_TELEMETRY": "1", "DO_NOT_TRACK": "1",
        "TOKENIZERS_PARALLELISM": "false",
        "NEEDLE_TELEMETRY": "0",
    }


def worker(job_path):
    os.umask(0o077)
    os.environ.update(offline_environment())
    # Redirect even native libraries' fd 1 writes; only emit() owns the NDJSON fd.
    protocol = os.fdopen(os.dup(sys.stdout.fileno()), "w", encoding="utf-8", buffering=1)
    os.dup2(sys.stderr.fileno(), sys.stdout.fileno())

    def emit(record):
        protocol.write(json.dumps(record, ensure_ascii=False, allow_nan=False) + "\n")
        protocol.flush()

    def interrupted(_signum, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupted)
    backend = None
    failed = False
    try:
        job = json.loads(Path(job_path).read_text(encoding="utf-8"))
        model_path = Path(job["model_path"])
        if not model_path.exists():
            raise ValueError("Local weights disappeared before loading")
        from backends import MODEL_SPECS, load_backend

        with ProcessTreeSampler() as load_sampler:
            started = time.perf_counter()
            backend = load_backend(job["model"], model_path, job["threads"])
            load_ms = (time.perf_counter() - started) * 1000
        emit({
            "type": "loaded", "model": job["model"], "load_ms": load_ms,
            "model_spec": MODEL_SPECS[job["model"]],
            "backend_info": getattr(backend, "info", None),
            "load_resources": load_sampler.result(),
        })
        calls = 0
        for clip in job["clips"]:
            if job["model"] == "canary" and clip["language"] == "auto":
                emit({
                    "type": "skipped", "model": job["model"], "clip_id": clip["clip_id"],
                    "reason": "Canary requires language.txt (pl/en) or --language pl/en",
                })
                continue
            for repeat in range(job["repeats"]):
                first = calls == 0
                texts, languages, mlx_peaks = [], [], []
                truncated = False
                cold_ms = None
                warm_ms = 0.0
                warm_audio = 0.0
                warm_calls = 0
                with ProcessTreeSampler() as sampler:
                    for chunk in clip["chunks"]:
                        with wave.open(chunk, "rb") as audio:
                            duration = audio.getnframes() / audio.getframerate()
                        started = time.perf_counter()
                        result = backend.transcribe(Path(chunk), language=clip["language"])
                        elapsed = (time.perf_counter() - started) * 1000
                        if calls == 0:
                            cold_ms = elapsed
                        else:
                            warm_ms += elapsed
                            warm_audio += duration
                            warm_calls += 1
                        calls += 1
                        if not isinstance(result.get("text"), str):
                            raise TypeError("Backend result text must be a string")
                        texts.append(result["text"])
                        languages.append(result.get("language"))
                        truncated |= bool(result.get("truncated", False))
                        peak = result.get("mlx_peak_bytes")
                        if peak is not None:
                            mlx_peaks.append(peak)
                text = " ".join(part.strip() for part in texts if part.strip())
                inference_ms = warm_ms + (cold_ms or 0.0)
                highwater = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
                emit({
                    "type": "sample", "model": job["model"], "clip_id": clip["clip_id"],
                    "repeat": repeat, "text": text, "language": clip["language"],
                    "detected_chunk_languages": languages, "truncated": truncated,
                    "chunk_count": len(clip["chunks"]), "inference_ms": inference_ms,
                    "timing_class": "contains_first_call" if first else "warm",
                    "first_call_ms": cold_ms, "warm_inference_ms": warm_ms if warm_calls else None,
                    "warm_chunk_calls": warm_calls, "warm_audio_seconds": warm_audio,
                    "warm_rtf": warm_ms / 1000 / warm_audio if warm_audio else None,
                    "audio_duration_seconds": clip["audio_duration_seconds"],
                    "rtf": inference_ms / 1000 / clip["audio_duration_seconds"],
                    "normalization_ms": clip["normalization_ms"],
                    "mlx_peak_bytes": max(mlx_peaks) if mlx_peaks else None,
                    "worker_lifetime_ru_maxrss_bytes": highwater if sys.platform == "darwin" else highwater * 1024,
                    **sampler.result(), **word_error(clip["reference"], text),
                })
    except BaseException as error:  # noqa: BLE001 — preserve failures and interrupts in the protocol
        failed = True
        traceback.print_exc(file=sys.stderr)
        emit({"type": "error", "error_type": type(error).__name__})
    finally:
        if backend is not None:
            try:
                backend.close()
            except BaseException as error:  # noqa: BLE001 — close failures must mark the worker incomplete
                failed = True
                traceback.print_exc(file=sys.stderr)
                emit({"type": "error", "phase": "close", "error_type": type(error).__name__})
        emit({"type": "finished", "ok": not failed})
        protocol.close()
    return 1 if failed else 0


def percentile(values, fraction):
    if not values:
        return None
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    low, high = math.floor(position), math.ceil(position)
    return ordered[low] + (ordered[high] - ordered[low]) * (position - low)


def distribution(values):
    return {"n": len(values), "p50": percentile(values, 0.5), "p95": percentile(values, 0.95)}


def summarize_model(records, clips, repeats, exit_status, timed_out):
    samples = [record for record in records if record.get("type") == "sample"]
    loaded = next((record for record in records if record.get("type") == "loaded"), None)
    finished = any(record.get("type") == "finished" and record.get("ok") for record in records)
    skipped = {record["clip_id"] for record in records if record.get("type") == "skipped"}
    expected = (len(clips) - len(skipped)) * repeats
    warm = [record for record in samples if record["timing_class"] == "warm"]
    by_clip = {}
    for sample in samples:
        by_clip.setdefault(sample["clip_id"], sample)
    scored = [sample for sample in by_clip.values() if sample["reference_words"] is not None]
    numerator = sum(sample["word_errors"] for sample in scored)
    denominator = sum(sample["reference_words"] for sample in scored)
    return {
        "status": "complete" if exit_status == 0 and finished and len(samples) == expected else "incomplete",
        "exit_status": exit_status, "timed_out": timed_out,
        "load_ms": loaded["load_ms"] if loaded else None,
        "model_spec": loaded.get("model_spec") if loaded else None,
        "backend_info": loaded.get("backend_info") if loaded else None,
        "load_resources": loaded.get("load_resources") if loaded else None,
        "first_call_ms": next((s["first_call_ms"] for s in samples if s["first_call_ms"] is not None), None),
        "sample_count": len(samples), "expected_sample_count": expected,
        "skipped_clip_count": len(skipped),
        "warm_inference_ms": distribution([s["inference_ms"] for s in warm]),
        "warm_rtf": distribution([s["rtf"] for s in warm]),
        "sampled_peak_process_tree_rss_bytes": distribution([s["sampled_peak_process_tree_rss_bytes"] for s in samples]),
        "sampled_process_tree_cpu_seconds": distribution([s["sampled_process_tree_cpu_seconds"] for s in samples]),
        "mlx_peak_bytes": distribution([s["mlx_peak_bytes"] for s in samples if s["mlx_peak_bytes"] is not None]),
        "warm_total_audio_seconds": sum(s["audio_duration_seconds"] for s in warm),
        "warm_corpus_rtf": (
            sum(s["inference_ms"] for s in warm) / 1000
            / sum(s["audio_duration_seconds"] for s in warm)
        ) if warm else None,
        "truncated_sample_count": sum(s["truncated"] for s in samples),
        "wer": numerator / denominator if denominator else None,
        "word_errors": numerator, "reference_words": denominator,
        "scored_clip_count": len(scored),
        "unknown_reference_clip_count": sum(c["reference"] is None for c in clips),
        "unscored_known_reference_clip_count": sum(c["reference"] is not None for c in clips) - len(scored),
        "wer_sample_policy": "first successful repeat per clip, never repeats pooled",
    }


def stop_worker(process):
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass
    # The worker can exit before an independently surviving child does.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def execute_model(run_dir, model, path, clips, args):
    job_path = run_dir / f"{model}.job.json"
    private_json(job_path, {
        "model": model, "model_path": str(path), "clips": clips,
        "threads": args.threads, "repeats": args.repeats,
    })
    records_path = run_dir / f"{model}.jsonl"
    interrupted = False
    timed_out = False
    started = time.perf_counter()
    with records_path.open("w", encoding="utf-8") as records, (run_dir / f"{model}.runtime.log").open("w") as log:
        process = subprocess.Popen(
            [sys.executable, str(Path(__file__).resolve()), "_worker", str(job_path)],
            stdin=subprocess.DEVNULL, stdout=records, stderr=log,
            env={**os.environ, **offline_environment()}, start_new_session=True,
        )
        try:
            process.wait(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            stop_worker(process)
        except KeyboardInterrupt:
            interrupted = True
            stop_worker(process)
    records = []
    malformed = False
    for line in records_path.read_text(encoding="utf-8").splitlines():
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            malformed = True
    summary = summarize_model(records, clips, args.repeats, process.returncode, timed_out)
    summary["worker_wall_ms"] = (time.perf_counter() - started) * 1000
    if malformed or interrupted:
        summary["status"] = "incomplete"
    summary["malformed_protocol"] = malformed
    summary["interrupted"] = interrupted
    return summary


def model_paths(args):
    paths = {name: (args.models_dir.expanduser() / LOCAL_PATHS[name]).resolve() for name in MODEL_NAMES}
    for override in args.weights:
        name, separator, value = override.partition("=")
        if name not in MODEL_NAMES or not separator or not value:
            raise BenchmarkInputError("--weights requires NAME=PATH with a supported model name")
        paths[name] = Path(value).expanduser().resolve()
    return paths


def has_module(name):
    try:
        return importlib.util.find_spec(name) is not None
    except (ImportError, ValueError):
        return False


def check_models(paths, selected):
    binary = os.environ.get("ASR_WHISPER_SERVER")
    whisper_ready = bool(binary and shutil.which(binary))
    needle_library = os.environ.get("ASR_NEEDLE_LIBRARY")
    availability = {
        "whisper": whisper_ready, "whistle": bool(needle_library and Path(needle_library).is_file()),
        "parakeet": has_module("mlx_audio"), "canary": has_module("mlx_audio"),
        "qwen": has_module("mlx_audio"),
    }
    return {
        name: {
            "weights_path": str(paths[name]), "weights_present": paths[name].exists(),
            "runtime_present": availability[name],
            "runtime_requirement": "ASR_WHISPER_SERVER executable" if name == "whisper" else "ASR_NEEDLE_LIBRARY native library" if name == "whistle" else "mlx_audio",
            "model_spec": MODEL_SPECS[name],
        }
        for name in selected
    }


def ensure_external_output(root):
    root = root.expanduser().resolve()
    repository = Path(__file__).resolve().parents[2]
    if root == repository or repository in root.parents or any(
        (parent / ".git").exists() for parent in (root, *root.parents)
    ):
        raise BenchmarkInputError("Benchmark output must be outside repository checkouts")
    return root


def run(args, paths):
    clips, ignored = discover_clips(args.archive_dir.expanduser(), args.language, args.limit)
    if not clips:
        print("No completed recordings selected; no output or workers created.", file=sys.stderr)
        return 1
    if shutil.which("ffmpeg") is None:
        raise BenchmarkInputError("ffmpeg is required on PATH")
    selected = list(dict.fromkeys(args.models))
    fingerprints, skipped = {}, {}
    for name in selected:
        if not paths[name].exists():
            skipped[name] = {"status": "skipped", "reason": "local weights missing"}
            continue
        try:
            fingerprints[name] = model_fingerprint(paths[name])
        except (OSError, ValueError) as error:
            skipped[name] = {"status": "skipped", "reason": "weights fingerprint failed", "error_type": type(error).__name__}
    if not fingerprints:
        print("No selected model has usable local weights; no workers created.", file=sys.stderr)
        return 1
    root = ensure_external_output(args.output_dir)
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    root.chmod(0o700)
    run_dir = root / (datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex)
    run_dir.mkdir(mode=0o700)
    manifest = {
        "schema_version": 1, "created_at": datetime.now(timezone.utc).isoformat(),
        "runtime": runtime_versions(), "models": fingerprints,
        "selected_models": selected, "repeats": args.repeats, "threads": args.threads,
        "worker_timeout_seconds": args.timeout,
        "timeout_scope": "entire model worker including load, all clips, repeats and close",
        "chunk_policy": {"sample_rate": SAMPLE_RATE, "channels": 1, "sample_format": "PCM16", "maximum_seconds": CHUNK_SECONDS, "overlap_seconds": 0, "text_join": "space in chronological order"},
        "cold_policy": "new process; first transcribe call cold-ish; weight fingerprinting warms filesystem caches; not a disk-cold measurement",
        "warm_policy": "summary p50/p95 use only full clip repeats after first call; mixed first clip warm chunk sum is recorded separately",
        "memory_policy": {"rss_interval_seconds": RSS_INTERVAL, "rss": "sampled sum of worker and descendant RSS, not unique physical or unified allocations", "cpu": "sampled process-tree CPU delta; short-lived children can be missed", "ru_maxrss": "worker lifetime highwater, not per-clip peak", "mlx_peak": "maximum backend-reported chunk peak; backend scope may be cumulative"},
        "wer_normalizer": "Unicode NFC, casefold, remove Unicode punctuation/symbols, whitespace split; word Levenshtein",
        "reference_policy": "only optional reference.txt; transcript.txt is never ground truth",
        "request_policy": "language only; other archived decoding options, prompts and translation are not replayed",
        "ignored_noncompleted_recordings": ignored,
        "clips": [{k: v for k, v in clip.items() if k != "reference"} | {"has_reference": clip["reference"] is not None} for clip in clips],
    }
    private_json(run_dir / "manifest.json", manifest)
    summary = {
        "schema_version": 1,
        "status": "incomplete",
        "models": {name: {"status": "not_run"} for name in fingerprints} | skipped,
    }
    private_json(run_dir / "summary.json", summary)
    failed = bool(skipped)
    try:
        with tempfile.TemporaryDirectory(prefix="audio-", dir=run_dir) as temporary:
            os.chmod(temporary, 0o700)
            with (run_dir / "normalization.log").open("w") as log:
                normalize_clips(clips, Path(temporary), log)
            manifest["clips"] = [
                {k: v for k, v in clip.items() if k not in ("reference", "chunks")}
                | {"has_reference": clip["reference"] is not None, "chunk_count": len(clip["chunks"])}
                for clip in clips
            ]
            private_json(run_dir / "manifest.json", manifest)
            for name in fingerprints:
                result = execute_model(run_dir, name, paths[name], clips, args)
                summary["models"][name] = result
                failed |= result["status"] != "complete" or result["skipped_clip_count"] > 0
                private_json(run_dir / "summary.json", summary)
                if result["interrupted"]:
                    raise KeyboardInterrupt
    except BaseException as error:  # noqa: BLE001 — always persist an incomplete summary, including interrupts
        failed = True
        summary["error_type"] = type(error).__name__
        with (run_dir / "orchestration.log").open("a") as log:
            traceback.print_exc(file=log)
    summary["status"] = "incomplete" if failed else "complete"
    private_json(run_dir / "summary.json", summary)
    print(f"Benchmark {summary['status']}. Private results: {run_dir}")
    return 1 if failed else 0


def positive_int(value):
    number = int(value)
    if number <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return number


def positive_seconds(value):
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise argparse.ArgumentTypeError("must be finite and positive")
    return number


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    subcommands = result.add_subparsers(dest="command", required=True)
    for command in ("list", "check", "run"):
        child = subcommands.add_parser(command)
        child.add_argument("--models-dir", type=Path, default=DEFAULT_MODELS_DIR)
        child.add_argument("--weights", action="append", default=[], metavar="NAME=PATH")
        child.add_argument("--models", nargs="+", choices=MODEL_NAMES, default=list(MODEL_NAMES))
        if command == "run":
            child.add_argument("--archive-dir", type=Path, default=DEFAULT_ARCHIVE)
            child.add_argument("--output-dir", "--output-root", type=Path, default=DEFAULT_OUTPUT, help="private output root; each run creates a unique child outside repositories")
            child.add_argument("--language", choices=("auto", "pl", "en"), default=None)
            child.add_argument("--repeats", type=positive_int, default=3)
            child.add_argument("--limit", type=positive_int)
            child.add_argument("--threads", type=positive_int, default=4)
            child.add_argument("--timeout", type=positive_seconds, default=600, help="hard orchestration limit in seconds for an entire model worker, not each request")
    return result


def main():
    os.umask(0o077)
    if len(sys.argv) == 3 and sys.argv[1] == "_worker":
        return worker(sys.argv[2])
    args = parser().parse_args()
    try:
        paths = model_paths(args)
        if args.command == "list":
            for name in args.models:
                print(f"{name}\t{MODEL_SPECS[name]['label']}\t{paths[name]}\t{'installed' if paths[name].exists() else 'missing'}")
            return 0
        if args.command == "check":
            checks = check_models(paths, args.models)
            ffmpeg_present = shutil.which("ffmpeg") is not None
            print(json.dumps({"models": checks, "ffmpeg_present": ffmpeg_present, "models_loaded": False}, indent=2))
            return 0 if ffmpeg_present and all(c["weights_present"] and c["runtime_present"] for c in checks.values()) else 1
        return run(args, paths)
    except (OSError, ValueError) as error:
        # Archive/decoder exception messages can contain private data.
        message = str(error) if isinstance(error, BenchmarkInputError) else type(error).__name__
        print(f"Benchmark cannot proceed: {message}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("Benchmark interrupted.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
