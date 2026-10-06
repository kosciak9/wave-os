"""Local-only backends; importing this module never loads a runtime or weights."""

import ctypes
import hashlib
import json
import os
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import uuid
import wave
from pathlib import Path


MODEL_SPECS = {
    "whisper": {
        "label": "Whisper large-v3-turbo Q5_0",
        "model_id": "ggerganov/whisper.cpp",
        "relative_path": "whisper/ggml-large-v3-turbo-q5_0.bin",
        "runtime": "whisper.cpp (isolated local server)",
    },
    "parakeet": {
        "label": "Parakeet TDT 0.6B v3",
        "model_id": "mlx-community/parakeet-tdt-0.6b-v3",
        "relative_path": "parakeet",
        "runtime": "mlx-audio",
    },
    "canary": {
        "label": "Canary 1B v2 Q8",
        "model_id": "Mediform/canary-1b-v2-mlx-q8",
        "relative_path": "canary",
        "runtime": "mlx-audio",
    },
    "qwen": {
        "label": "Qwen3-ASR 1.7B 8-bit",
        "model_id": "mlx-community/Qwen3-ASR-1.7B-8bit",
        "relative_path": "qwen",
        "runtime": "mlx-audio",
    },
    "whistle": {
        "label": "Whistle",
        "model_id": "Cactus-Compute/whistle",
        "relative_path": "whistle/whistle.cact",
        "runtime": "Needle native C API (CPU)",
    },
}


class WhisperBackend:
    def __init__(self, path, threads):
        self.process = None
        self.temporary = tempfile.TemporaryDirectory(prefix="asr-whisper-")
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        self.endpoint = f"http://127.0.0.1:{port}"
        self.info = {
            "runtime_version": os.environ.get("ASR_WHISPER_VERSION"),
            "threads": threads,
            "settings": {"language": "auto", "no_timestamps": True, "convert": True},
            "timing_scope": "local HTTP multipart roundtrip including backend FFmpeg",
        }
        try:
            self.process = subprocess.Popen(
                [
                    os.environ["ASR_WHISPER_SERVER"], "--model", str(path),
                    "--host", "127.0.0.1", "--port", str(port),
                    "--inference-path", "/v1/audio/transcriptions",
                    "--language", "auto", "--no-timestamps", "--convert",
                    "--threads", str(threads), "--tmp-dir", self.temporary.name,
                ],
                stdin=subprocess.DEVNULL,
            )
            deadline = time.monotonic() + 300
            while time.monotonic() < deadline:
                if self.process.poll() is not None:
                    raise RuntimeError("Isolated Whisper server exited before becoming ready")
                try:
                    with self.opener.open(self.endpoint + "/", timeout=0.5) as response:
                        if response.status == 200 and "whisper.cpp" in response.headers.get("Server", ""):
                            return
                except (urllib.error.URLError, TimeoutError):
                    pass
                time.sleep(0.05)
            raise TimeoutError("Isolated Whisper server startup timed out")
        except BaseException:
            self.close()
            raise

    def transcribe(self, wav_path, language="auto"):
        boundary = uuid.uuid4().hex
        body = bytearray()
        for name, value in {"language": language, "response_format": "json"}.items():
            body.extend(
                f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode()
            )
        body.extend(
            f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="audio.wav"\r\nContent-Type: audio/wav\r\n\r\n'.encode()
        )
        body.extend(wav_path.read_bytes())
        body.extend(f"\r\n--{boundary}--\r\n".encode())
        request = urllib.request.Request(
            self.endpoint + "/v1/audio/transcriptions", data=bytes(body),
            headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
        )
        with self.opener.open(request, timeout=600) as response:
            result = json.load(response)
        return {
            "text": result["text"], "language": result.get("language"),
            "truncated": False, "mlx_peak_bytes": None,
        }

    def close(self):
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.temporary.cleanup()


class MlxBackend:
    def __init__(self, name, path):
        import mlx.core as mx
        from mlx_audio.stt import load

        self.mx = mx
        self.name = name
        # Path (not a Hub ID) bypasses snapshot resolution; offline mode also covers tokenizers.
        self.model = load(path, strict=True)
        mx.eval(self.model.parameters())
        mx.synchronize()
        self.info = {
            "language_policy": "automatic only" if name == "parakeet" else "requested language",
            "max_tokens": 1024 if name in {"canary", "qwen"} else None,
            "mlx_memory_scope": "per chunk allocation peak, includes resident model; excludes non-MLX memory",
            "timing_scope": "WAV read, feature extraction, inference and synchronization",
        }

    def transcribe(self, wav_path, language="auto"):
        self.mx.reset_peak_memory()
        kwargs = {"verbose": False}
        if self.name == "canary":
            if language not in {"pl", "en"}:
                raise ValueError("Canary needs an explicit pl/en language")
            kwargs.update(source_lang=language, target_lang=language, max_tokens=1024)
        elif self.name == "qwen":
            kwargs.update(
                language={"pl": "Polish", "en": "English", "auto": None}[language],
                max_tokens=1024, temperature=0.0,
            )
        result = self.model.generate(str(wav_path), **kwargs)
        self.mx.synchronize()
        return {
            "text": result.text,
            "language": None if self.name == "parakeet" else getattr(result, "language", None),
            "truncated": getattr(result, "generation_tokens", 0) >= 1024,
            "mlx_peak_bytes": self.mx.get_peak_memory(),
        }

    def close(self):
        self.mx.synchronize()
        self.model = None
        self.mx.clear_cache()


class WhistleBackend:
    def __init__(self, path):
        import numpy as np

        self.np = np
        library_path = Path(os.environ["ASR_NEEDLE_LIBRARY"])
        self.lib = ctypes.CDLL(str(library_path))
        self.lib.needle_load.argtypes = [ctypes.c_char_p, ctypes.c_uint64]
        self.lib.needle_load.restype = ctypes.c_int
        self.lib.needle_last_error.argtypes = []
        self.lib.needle_last_error.restype = ctypes.c_char_p
        self.lib.needle_transcribe.argtypes = [
            ctypes.POINTER(ctypes.c_float), ctypes.c_int, ctypes.c_char_p,
            ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_int,
        ]
        self.lib.needle_transcribe.restype = ctypes.c_int
        weights = path.read_bytes()
        if self.lib.needle_load(weights, len(weights)) < 0:
            raise RuntimeError(self.lib.needle_last_error().decode("utf-8", errors="replace"))
        self.buffer = ctypes.create_string_buffer(1 << 18)
        self.info = {
            "runtime_version": os.environ.get("ASR_NEEDLE_VERSION"),
            "library_sha256": hashlib.sha256(library_path.read_bytes()).hexdigest(),
            "maximum_audio_seconds": 30, "maximum_tokens": 320,
            "threads": "native engine default", "device": "CPU",
            "timing_scope": "WAV read, PCM conversion and native needle_transcribe",
        }

    def transcribe(self, wav_path, language="auto"):
        with wave.open(str(wav_path), "rb") as source:
            if (source.getframerate(), source.getnchannels(), source.getsampwidth()) != (16000, 1, 2):
                raise ValueError("Whistle requires normalized 16kHz mono PCM16")
            if source.getnframes() > 30 * 16000:
                raise ValueError("Whistle audio exceeds 30 seconds")
            pcm = self.np.frombuffer(source.readframes(source.getnframes()), dtype="<i2")
        samples = pcm.astype(self.np.float32) / 32768.0
        count = self.lib.needle_transcribe(
            samples.ctypes.data_as(ctypes.POINTER(ctypes.c_float)), len(samples),
            None if language == "auto" else language.encode("ascii"), None, 0,
            self.buffer, len(self.buffer),
        )
        if count < 0:
            raise RuntimeError(self.lib.needle_last_error().decode("utf-8", errors="replace"))
        result = json.loads(self.buffer.value)
        return {
            "text": result["text"], "language": result.get("language"),
            "truncated": count >= 320, "mlx_peak_bytes": None,
        }

    def close(self):
        # The native API has no unload; the isolated model worker exits after close.
        pass


def load_backend(name, model_path, threads):
    if not model_path.exists():
        raise FileNotFoundError("Local model weights required; downloads are disabled")
    os.environ.update({
        "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1",
        "NEEDLE_TELEMETRY": "0", "DO_NOT_TRACK": "1",
    })
    if name in {"whisper", "whistle"}:
        if not model_path.is_file():
            raise ValueError("Backend requires a local model file")
        return WhisperBackend(model_path, threads) if name == "whisper" else WhistleBackend(model_path)
    if not model_path.is_dir() or not (model_path / "config.json").is_file():
        raise ValueError("MLX backend requires a local checkpoint directory with config.json")
    return MlxBackend(name, model_path)
