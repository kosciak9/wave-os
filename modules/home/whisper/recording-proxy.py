import argparse
import asyncio
import hashlib
import json
import os
import sys
import time
import uuid
from datetime import datetime, timezone
from email import policy
from email.parser import BytesParser
from pathlib import Path

from aiohttp import ClientSession, ClientTimeout, web


INFERENCE_PATH = "/v1/audio/transcriptions"
HOP_HEADERS = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailer", "transfer-encoding", "upgrade", "content-length", "host",
}
AUDIO_SUFFIXES = {".wav", ".ogg", ".opus", ".mp3", ".m4a", ".mp4", ".flac", ".webm"}


def proxy_headers(headers):
    excluded = HOP_HEADERS | {
        name.strip().lower() for name in headers.get("Connection", "").split(",")
    }
    return [(name, value) for name, value in headers.items() if name.lower() not in excluded]


def write_metadata(directory, metadata):
    temporary = directory / "metadata.json.tmp"
    temporary.write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
    temporary.replace(directory / "metadata.json")


def archive_request(root, content_type, body, backend, received_at):
    # Never persist HTTP headers: clients can supply credentials and private addresses.
    message = BytesParser(policy=policy.default).parsebytes(
        b"Content-Type: " + content_type.encode("ascii") + b"\r\n\r\n" + body
    )
    if not message.is_multipart():
        raise ValueError("Expected multipart audio upload")

    fields = {}
    audio = None
    suffix = ".bin"
    audio_type = None
    for part in message.iter_parts():
        name = part.get_param("name", header="content-disposition")
        payload = part.get_payload(decode=True)
        if not isinstance(payload, bytes):
            raise ValueError("Invalid multipart payload")
        if name == "file" and audio is None:
            audio = payload
            candidate = Path(part.get_filename() or "").suffix.lower()
            suffix = candidate if candidate in AUDIO_SUFFIXES else ".bin"
            audio_type = part.get_content_type()
        elif name and part.get_filename() is None:
            fields.setdefault(name, []).append(payload.decode("utf-8", errors="replace"))
    if audio is None:
        raise ValueError("Missing audio upload")

    directory = root / f"{received_at:%Y%m%dT%H%M%S}-{uuid.uuid4().hex}"
    directory.mkdir(mode=0o700)
    audio_name = "audio" + suffix
    (directory / audio_name).write_bytes(audio)
    metadata = {
        "schema_version": 1,
        "received_at": received_at.isoformat(),
        "state": "pending",
        "audio_file": audio_name,
        "audio_bytes": len(audio),
        "audio_sha256": hashlib.sha256(audio).hexdigest(),
        "audio_content_type": audio_type,
        "request_fields": fields,
        "backend": backend,
    }
    write_metadata(directory, metadata)
    return directory, metadata


def archive_response(directory, metadata, body, content_type):
    (directory / "response.bin").write_bytes(body)
    metadata["response_content_type"] = content_type
    metadata["response_file"] = "response.bin"
    response_format = metadata["request_fields"].get("response_format", ["json"])[0]
    if response_format in {"json", "verbose_json"}:
        try:
            text = json.loads(body).get("text")
        except (ValueError, AttributeError, UnicodeError):
            text = None
    elif response_format == "text":
        text = body.decode("utf-8", errors="replace")
    else:
        text = None
    if isinstance(text, str):
        (directory / "transcript.txt").write_text(text)
        metadata["transcript_file"] = "transcript.txt"


def archive_warning(error):
    # Exception messages may contain user-controlled data; only log the type.
    print(f"whisper recording: archive failed ({type(error).__name__})", file=sys.stderr)


def make_app(args):
    root = Path(args.archive_dir)
    backend = {"model": args.backend_model, "runtime": "whisper.cpp", "version": args.backend_version}
    session_key = web.AppKey("session", ClientSession)

    async def session_context(app):
        async with ClientSession(
            timeout=ClientTimeout(total=None, sock_connect=10, sock_read=600),
            auto_decompress=False,
            skip_auto_headers={"Content-Type", "User-Agent"},
        ) as session:
            app[session_key] = session
            yield

    async def transcribe(request):
        received_at = datetime.now(timezone.utc)
        started = time.monotonic()
        body = await request.read()
        request_body_read_ms = (time.monotonic() - started) * 1000
        directory = None
        metadata = {}
        capture_started = time.monotonic()
        if not (root / "recording-disabled").exists():
            try:
                root.mkdir(mode=0o700, parents=True, exist_ok=True)
                root.chmod(0o700)
                directory, metadata = archive_request(
                    root, request.headers.get("Content-Type", ""), body, backend, received_at
                )
            except Exception as error:
                archive_warning(error)
        capture_ms = (time.monotonic() - capture_started) * 1000
        upstream_started = time.monotonic()
        status = None
        response_body = None
        content_type = None
        state = "upstream_error"
        try:
            async with request.app[session_key].post(
                args.upstream + INFERENCE_PATH,
                data=body,
                headers=proxy_headers(request.headers),
                allow_redirects=False,
            ) as response:
                status = response.status
                response_body = await response.read()
                content_type = response.headers.get("Content-Type", "")
                state = "completed" if 200 <= status < 300 else "http_error"
                return web.Response(
                    status=status, body=response_body, headers=proxy_headers(response.headers)
                )
        except asyncio.CancelledError:
            state = "client_disconnected"
            raise
        except TimeoutError:
            return web.json_response({"error": "Transcription backend timed out"}, status=504)
        except Exception as error:
            print(f"whisper recording: upstream failed ({type(error).__name__})", file=sys.stderr)
            return web.json_response({"error": "Transcription backend unavailable"}, status=502)
        finally:
            # This includes upstream queueing and FFmpeg, not just model inference.
            upstream_ms = (time.monotonic() - upstream_started) * 1000
            if directory is not None:
                try:
                    metadata.update({
                        "state": state,
                        "http_status": status,
                        "request_body_read_ms": request_body_read_ms,
                        "request_archive_ms": capture_ms,
                        "upstream_ms": upstream_ms,
                        "response_received_at": datetime.now(timezone.utc).isoformat(),
                    })
                    response_archive_started = time.monotonic()
                    if response_body is not None:
                        archive_response(directory, metadata, response_body, content_type)
                    metadata["response_archive_ms"] = (time.monotonic() - response_archive_started) * 1000
                    write_metadata(directory, metadata)
                except Exception as error:
                    archive_warning(error)

    async def options(_request):
        return web.Response(headers={
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Headers": "content-type, authorization",
        })

    app = web.Application(client_max_size=0)
    app.cleanup_ctx.append(session_context)
    app.router.add_post(INFERENCE_PATH, transcribe)
    app.router.add_options(INFERENCE_PATH, options)
    return app


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18080)
    parser.add_argument("--upstream", default="http://127.0.0.1:18081")
    parser.add_argument("--archive-dir", required=True)
    parser.add_argument("--backend-model", required=True)
    parser.add_argument("--backend-version", required=True)
    args = parser.parse_args()
    os.umask(0o077)
    web.run_app(make_app(args), host="127.0.0.1", port=args.port,
                access_log=None, handler_cancellation=True)
