import asyncio
import html
import io
import math
import os
import sqlite3
import sys
import time
import uuid
import wave
from contextlib import closing
from datetime import datetime
from pathlib import Path
from string import Template
from urllib.parse import urlsplit

from fastapi import Depends, HTTPException, Query, Request
from fastapi.responses import HTMLResponse, JSONResponse, Response
from litellm.integrations.custom_logger import CustomLogger
from prometheus_client import CONTENT_TYPE_LATEST, CollectorRegistry, generate_latest
from prometheus_client.core import CounterMetricFamily, HistogramMetricFamily

PROVIDERS = ("renekton", "openrouter-scribe")
CONTEXT_KEY = "wave_dictation_history"
LATENCY_BUCKETS = (0.1, 0.25, 0.5, 1, 2, 5, 10, 20, 30, 45, 60, 90, 120, 180, 210)
PAGE_HEADERS = {
    "Cache-Control": "no-store",
    "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
    "X-Content-Type-Options": "nosniff",
}


def context(data):
    for key in ("metadata", "litellm_metadata"):
        metadata = data.get(key) or {}
        if isinstance(metadata, dict) and CONTEXT_KEY in metadata:
            return metadata[CONTEXT_KEY]
    return None


def local_only(request: Request):
    origin = request.headers.get("origin")
    if request.url.hostname not in {"localhost", "127.0.0.1", "::1"} or (
        origin and urlsplit(origin).netloc != request.url.netloc
    ):
        raise HTTPException(status_code=403, detail="Local access only")


def percentile(values, fraction):
    if not values:
        return None
    values = sorted(values)
    return values[math.ceil(len(values) * fraction) - 1]


def number(value, suffix=""):
    return "—" if value is None else f"{value:.2f}{suffix}"


def table_row(values):
    return (
        "<tr>"
        + "".join(f"<td>{html.escape(str(value))}</td>" for value in values)
        + "</tr>"
    )


class DictationHistory(CustomLogger):
    def __init__(self):
        super().__init__(turn_off_message_logging=True)
        self.path = Path(os.environ["WAVE_DICTATION_HISTORY"])
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.path.parent.chmod(0o700)
        with closing(sqlite3.connect(self.path)) as db:
            db.execute("PRAGMA journal_mode=WAL")
            db.executescript("""
                CREATE TABLE IF NOT EXISTS requests (
                    id TEXT PRIMARY KEY,
                    started_at REAL NOT NULL,
                    audio_seconds REAL,
                    finished_at REAL,
                    success INTEGER,
                    elapsed_seconds REAL,
                    status_code INTEGER
                );
                CREATE INDEX IF NOT EXISTS requests_started_at ON requests(started_at);
                CREATE TABLE IF NOT EXISTS attempts (
                    id TEXT PRIMARY KEY,
                    request_id TEXT NOT NULL REFERENCES requests(id),
                    provider TEXT NOT NULL,
                    started_at REAL NOT NULL,
                    finished_at REAL,
                    success INTEGER,
                    elapsed_seconds REAL,
                    status_code INTEGER,
                    error_type TEXT,
                    cost_usd REAL
                );
                CREATE INDEX IF NOT EXISTS attempts_request_id ON attempts(request_id);
            """)
        self.path.chmod(0o600)
        self.page = Template(Path(__file__).with_suffix(".html").read_text())
        self.registry = CollectorRegistry()
        self.registry.register(self)

        from litellm.proxy.proxy_server import app

        app.add_api_route(
            "/dictation",
            self.dashboard,
            methods=["GET"],
            include_in_schema=False,
            dependencies=[Depends(local_only)],
        )
        app.add_api_route(
            "/dictation/api",
            self.metrics,
            methods=["GET"],
            include_in_schema=False,
            dependencies=[Depends(local_only)],
        )
        app.add_api_route(
            "/dictation/metrics",
            self.prometheus,
            methods=["GET"],
            include_in_schema=False,
            dependencies=[Depends(local_only)],
        )

    def write(self, statement, parameters):
        try:
            with closing(sqlite3.connect(self.path)) as db:
                db.execute(statement, parameters)
                db.commit()
        except sqlite3.Error as error:
            # Never turn a telemetry failure into a failed transcription or log its payload.
            print(
                f"voxtype history: write failed ({type(error).__name__})",
                file=sys.stderr,
            )

    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        if call_type != "transcription" or data.get("model") != "dictation":
            return
        audio_seconds = None
        audio = data.get("file")
        if isinstance(audio, io.BytesIO):
            position = audio.tell()
            try:
                with wave.open(audio, "rb") as recording:
                    audio_seconds = recording.getnframes() / recording.getframerate()
            except (wave.Error, EOFError):
                pass
            finally:
                audio.seek(position)
        ctx = {
            "request_id": uuid.uuid4().hex,
            "request_clock": time.monotonic(),
        }
        data.setdefault("metadata", {})[CONTEXT_KEY] = ctx
        await asyncio.to_thread(
            self.write,
            "INSERT INTO requests(id, started_at, audio_seconds) VALUES (?, ?, ?)",
            (ctx["request_id"], time.time(), audio_seconds),
        )

    async def async_pre_call_deployment_hook(self, kwargs, call_type):
        ctx = context(kwargs)
        provider = (kwargs.get("model_info") or {}).get("id")
        if ctx is None or provider not in PROVIDERS:
            return
        ctx = {**ctx, "attempt_id": uuid.uuid4().hex, "attempt_clock": time.monotonic()}
        # A fallback must not overwrite the previous attempt's logging context.
        for key in ("metadata", "litellm_metadata"):
            metadata = kwargs.get(key) or {}
            if CONTEXT_KEY in metadata:
                kwargs[key] = {**metadata, CONTEXT_KEY: ctx}
        await asyncio.to_thread(
            self.write,
            "INSERT INTO attempts(id, request_id, provider, started_at) VALUES (?, ?, ?, ?)",
            (ctx["attempt_id"], ctx["request_id"], provider, time.time()),
        )

    async def finish_attempt(self, data, success, exception=None):
        ctx = context(data)
        if ctx is None or "attempt_id" not in ctx:
            return
        status = 200 if success else getattr(exception, "status_code", None)
        status = status if isinstance(status, int) else None
        await asyncio.to_thread(
            self.write,
            """
            UPDATE attempts SET finished_at=?, success=?, elapsed_seconds=?, status_code=?, error_type=?
            WHERE id=? AND finished_at IS NULL
        """,
            (
                time.time(),
                success,
                time.monotonic() - ctx["attempt_clock"],
                status,
                type(exception).__name__ if exception else None,
                ctx["attempt_id"],
            ),
        )

    async def async_post_call_success_deployment_hook(
        self, request_data, response, call_type
    ):
        await self.finish_attempt(request_data, True)

    async def async_post_call_failure_deployment_hook(
        self, request_data, exception, call_type, fallback_depth=None
    ):
        await self.finish_attempt(request_data, False, exception)

    async def finish_request(self, data, success, status_code):
        ctx = context(data)
        if ctx is None:
            return
        await asyncio.to_thread(
            self.write,
            """
            UPDATE requests SET finished_at=?, success=?, elapsed_seconds=?, status_code=?
            WHERE id=? AND finished_at IS NULL
        """,
            (
                time.time(),
                success,
                time.monotonic() - ctx["request_clock"],
                status_code if isinstance(status_code, int) else None,
                ctx["request_id"],
            ),
        )

    async def async_post_call_response_headers_hook(
        self,
        data,
        user_api_key_dict,
        response,
        request_headers=None,
        litellm_call_info=None,
    ):
        if response is None:
            return
        await self.finish_request(data, True, 200)
        ctx = context(data)
        if ctx is None:
            return
        usage = getattr(response, "usage", None)
        cost = (
            usage.get("cost")
            if isinstance(usage, dict)
            else getattr(usage, "cost", None)
        )
        cost = (
            cost
            if isinstance(cost, (int, float)) and math.isfinite(cost) and cost >= 0
            else None
        )
        # Only provider-reported cost: LiteLLM's Whisper estimate is not OpenRouter's bill.
        await asyncio.to_thread(
            self.write,
            """
            UPDATE attempts SET cost_usd=CASE WHEN provider='renekton' THEN 0 ELSE ? END
            WHERE request_id=? AND success=1
        """,
            (cost, ctx["request_id"]),
        )

    async def async_post_call_failure_hook(
        self, request_data, original_exception, user_api_key_dict, traceback_str=None
    ):
        await self.finish_request(
            request_data, False, getattr(original_exception, "status_code", None)
        )

    def report(self, days):
        now = time.time()
        with closing(sqlite3.connect(f"file:{self.path}?mode=ro", uri=True)) as db:
            db.row_factory = sqlite3.Row
            db.execute("BEGIN")
            requests = [
                dict(row)
                for row in db.execute(
                    "SELECT * FROM requests WHERE started_at >= ? ORDER BY started_at",
                    (now - days * 86400,),
                )
            ]
            attempts = [
                dict(row)
                for row in db.execute(
                    """
                SELECT attempts.*, requests.audio_seconds FROM attempts JOIN requests ON requests.id=request_id
                WHERE requests.started_at >= ? ORDER BY attempts.started_at
            """,
                    (now - days * 86400,),
                )
            ]
            oldest = db.execute("SELECT MIN(started_at) FROM requests").fetchone()[0]
        by_request = {}
        for attempt in attempts:
            by_request.setdefault(attempt["request_id"], []).append(attempt)
        daily = {}
        for request in requests:
            selected = by_request.get(request["id"], [])
            request["used_openrouter"] = any(
                a["provider"] == "openrouter-scribe" for a in selected
            )
            request["recovered"] = (
                request["success"] == 1
                and request["used_openrouter"]
                and any(
                    a["provider"] == "renekton" and a["success"] == 0 for a in selected
                )
            )
            day = (
                datetime.fromtimestamp(request["started_at"])
                .astimezone()
                .date()
                .isoformat()
            )
            bucket = daily.setdefault(
                day,
                {
                    "date": day,
                    "requests": 0,
                    "successful": 0,
                    "failed": 0,
                    "unfinished": 0,
                    "openrouter": 0,
                    "renekton_successful": 0,
                    "renekton_failed": 0,
                    "openrouter_successful": 0,
                    "openrouter_failed": 0,
                },
            )
            bucket["requests"] += 1
            bucket[
                {1: "successful", 0: "failed", None: "unfinished"}[request["success"]]
            ] += 1
            bucket["openrouter"] += request["used_openrouter"]
            for attempt in selected:
                if attempt["success"] is not None:
                    provider = (
                        "renekton"
                        if attempt["provider"] == "renekton"
                        else "openrouter"
                    )
                    result = "successful" if attempt["success"] else "failed"
                    bucket[f"{provider}_{result}"] += 1
        providers = []
        for provider in PROVIDERS:
            selected = [a for a in attempts if a["provider"] == provider]
            successful = [a for a in selected if a["success"] == 1]
            failed = sum(a["success"] == 0 for a in selected)
            latencies = [a["elapsed_seconds"] for a in successful]
            audio = [
                a["audio_seconds"] for a in successful if a["audio_seconds"] is not None
            ]
            ratios = [
                a["elapsed_seconds"] / a["audio_seconds"]
                for a in successful
                if a["audio_seconds"]
            ]
            costs = [a["cost_usd"] for a in successful if a["cost_usd"] is not None]
            providers.append(
                {
                    "provider": provider,
                    "attempts": len(selected),
                    "successful": len(successful),
                    "failed": failed,
                    "unfinished": len(selected) - len(successful) - failed,
                    "success_rate": len(successful) / (len(successful) + failed)
                    if successful or failed
                    else None,
                    "latency_p50_seconds": percentile(latencies, 0.5),
                    "latency_p95_seconds": percentile(latencies, 0.95),
                    "audio_p50_seconds": percentile(audio, 0.5),
                    "rtf_p50": percentile(ratios, 0.5),
                    "reported_cost_usd": sum(costs) if costs else None,
                    "cost_samples": len(costs),
                }
            )
        return {
            "days": days,
            "generated_at": now,
            "history_since": oldest,
            "requests": len(requests),
            "successful": sum(r["success"] == 1 for r in requests),
            "failed": sum(r["success"] == 0 for r in requests),
            "unfinished": sum(r["success"] is None for r in requests),
            "openrouter_requests": sum(r["used_openrouter"] for r in requests),
            "recovered_requests": sum(r["recovered"] for r in requests),
            "request_latency_p50_seconds": percentile(
                [r["elapsed_seconds"] for r in requests if r["success"] == 1], 0.5
            ),
            "request_latency_p95_seconds": percentile(
                [r["elapsed_seconds"] for r in requests if r["success"] == 1], 0.95
            ),
            "providers": providers,
            "daily": list(daily.values()),
            "recent": attempts[-100:][::-1],
        }

    def collect(self):
        requests = CounterMetricFamily(
            "wave_dictation_requests", "Completed user requests", labels=["result"]
        )
        attempts = CounterMetricFamily(
            "wave_dictation_attempts",
            "Completed backend attempts",
            labels=["provider", "result"],
        )
        latency = HistogramMetricFamily(
            "wave_dictation_attempt_duration_seconds",
            "Backend attempt duration, excluding earlier failed attempts",
            labels=["provider", "result"],
        )
        cost = CounterMetricFamily(
            "wave_dictation_reported_cost_usd",
            "Known API costs only; excludes missing provider costs and local compute",
            labels=["provider"],
        )
        cost_samples = CounterMetricFamily(
            "wave_dictation_reported_cost_samples",
            "Successful attempts with known API cost",
            labels=["provider"],
        )
        bucket_columns = ", ".join(
            f"SUM(elapsed_seconds <= {bound}) AS bucket_{index}"
            for index, bound in enumerate(LATENCY_BUCKETS)
        )
        with closing(sqlite3.connect(f"file:{self.path}?mode=ro", uri=True)) as db:
            db.row_factory = sqlite3.Row
            db.execute("BEGIN")
            for row in db.execute(
                "SELECT success, COUNT(*) AS count FROM requests WHERE success IS NOT NULL GROUP BY success"
            ):
                requests.add_metric(
                    ["success" if row["success"] else "failure"], row["count"]
                )
            for row in db.execute(f"""
                SELECT provider, success, COUNT(*) AS count, SUM(elapsed_seconds) AS seconds, {bucket_columns}
                FROM attempts WHERE success IS NOT NULL GROUP BY provider, success
            """):
                labels = [row["provider"], "success" if row["success"] else "failure"]
                attempts.add_metric(labels, row["count"])
                buckets = [
                    (str(bound), row[f"bucket_{index}"])
                    for index, bound in enumerate(LATENCY_BUCKETS)
                ]
                latency.add_metric(
                    labels, [*buckets, ("+Inf", row["count"])], row["seconds"]
                )
            for row in db.execute(
                "SELECT provider, SUM(cost_usd) AS cost, COUNT(*) AS count FROM attempts WHERE cost_usd IS NOT NULL GROUP BY provider"
            ):
                cost.add_metric([row["provider"]], row["cost"])
                cost_samples.add_metric([row["provider"]], row["count"])
        yield from (requests, attempts, latency, cost, cost_samples)

    def prometheus(self):
        return Response(
            generate_latest(self.registry),
            media_type=CONTENT_TYPE_LATEST,
            headers={"Cache-Control": "no-store"},
        )

    def metrics(self, days: int = Query(default=7, ge=1, le=365)):
        return JSONResponse(self.report(days), headers=PAGE_HEADERS)

    def dashboard(self, days: int = Query(default=7, ge=1, le=365)):
        report = self.report(days)
        provider_rows = "".join(
            table_row(
                [
                    p["provider"],
                    p["attempts"],
                    p["successful"],
                    p["failed"],
                    p["unfinished"],
                    number(
                        p["success_rate"] * 100
                        if p["success_rate"] is not None
                        else None,
                        "%",
                    ),
                    number(p["latency_p50_seconds"], " s"),
                    number(p["latency_p95_seconds"], " s"),
                    number(p["audio_p50_seconds"], " s"),
                    number(p["rtf_p50"]),
                    "—"
                    if p["reported_cost_usd"] is None
                    else f"${p['reported_cost_usd']:.6f} ({p['cost_samples']} próbek)",
                ]
            )
            for p in report["providers"]
        )
        daily_rows = "".join(
            table_row(
                [
                    d["date"],
                    d["requests"],
                    d["successful"],
                    d["failed"],
                    d["unfinished"],
                    d["openrouter"],
                    f"{d['renekton_successful']} / {d['renekton_failed']}",
                    f"{d['openrouter_successful']} / {d['openrouter_failed']}",
                ]
            )
            for d in reversed(report["daily"])
        )
        recent_rows = "".join(
            table_row(
                [
                    datetime.fromtimestamp(a["started_at"])
                    .astimezone()
                    .isoformat(timespec="seconds"),
                    a["provider"],
                    "OK"
                    if a["success"] == 1
                    else "błąd"
                    if a["success"] == 0
                    else "nieukończona"
                    if report["generated_at"] - a["started_at"] > 210
                    else "w trakcie",
                    a["status_code"] or "—",
                    number(a["elapsed_seconds"], " s"),
                    number(a["audio_seconds"], " s"),
                    a["error_type"] or "—",
                ]
            )
            for a in report["recent"]
        )
        since = (
            datetime.fromtimestamp(report["history_since"])
            .astimezone()
            .isoformat(timespec="seconds")
            if report["history_since"]
            else "jeszcze brak żądań"
        )
        page = self.page.substitute(
            days=days,
            since=html.escape(since),
            providers=provider_rows,
            daily=daily_rows,
            recent=recent_rows,
            requests=report["requests"],
            successful=report["successful"],
            failed=report["failed"],
            unfinished=report["unfinished"],
            openrouter=report["openrouter_requests"],
            recovered=report["recovered_requests"],
            p50=number(report["request_latency_p50_seconds"], " s"),
            p95=number(report["request_latency_p95_seconds"], " s"),
        )
        return HTMLResponse(page, headers=PAGE_HEADERS)


history = DictationHistory()
