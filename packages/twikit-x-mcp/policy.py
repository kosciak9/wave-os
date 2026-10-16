"""Read-only MCP registration and a persistent, fail-closed HTTP budget."""

import asyncio
import fcntl
import functools
import inspect
import json
import logging
import math
import os
import random
import re
import time
from collections import OrderedDict
from email.utils import parsedate_to_datetime
from pathlib import Path

import httpx
from mcp.server.fastmcp.exceptions import ToolError
from mcp.types import ToolAnnotations

from twikit import Client
from twikit.client.gql import Endpoint
from twikit.client.v11 import Endpoint as V11Endpoint

TOOLS = json.loads(Path(__file__).with_name("tools.json").read_text())
READ_URLS = {getattr(Endpoint, name) for names in TOOLS.values() for name in names}
READ_URLS.add(V11Endpoint.SETTINGS)
# X serves these GraphQL queries over POST; the method alone does not imply a mutation.
POST_READ_URLS = {Endpoint.HOME_TIMELINE, Endpoint.HOME_LATEST_TIMELINE}
WINDOWS = ((900, 10), (3600, 30), (86400, 150))
MIN_INTERVAL = 20
JITTER = 20
CACHE_TTL = 120
MAX_RESULTS = 20
_policy = None

logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("httpcore").setLevel(logging.WARNING)


class PolicyError(ToolError):
    pass


class Policy:
    def __init__(self, directory):
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        # The bridge keeps one stdio process alive. A second one must not get a new budget.
        self.lock_file = (directory / "lock").open("a")
        fcntl.flock(self.lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.path = directory / "budget.json"
        self.state = {
            "requests": [], "next_request_at": 0, "cooldown_until": 0,
            "halt_reason": None, "failures": 0,
        }
        if self.path.exists():
            saved = json.loads(self.path.read_text())
            if saved.keys() != self.state.keys():
                raise ValueError("Unrecognised X budget state; refusing to reset it")
            if not isinstance(saved["requests"], list) or not all(
                isinstance(t, (int, float)) and math.isfinite(t) and t >= 0
                for t in saved["requests"]
            ):
                raise ValueError("Invalid X request history")
            for name in ("next_request_at", "cooldown_until", "failures"):
                if not isinstance(saved[name], (int, float)) or not math.isfinite(saved[name]) or saved[name] < 0:
                    raise ValueError("Invalid X budget state")
            self.state = saved
        self.http_lock = asyncio.Lock()
        self.tool_lock = asyncio.Lock()
        self.cache = OrderedDict()

    def save(self):
        temporary = self.path.with_suffix(".tmp")
        with temporary.open("w") as target:
            json.dump(self.state, target)
            target.flush()
            os.fsync(target.fileno())
        temporary.replace(self.path)

    def halt(self, reason):
        self.state["halt_reason"] = reason
        self.cache.clear()
        self.save()
        raise PolicyError(reason + " X access is stopped until the owner intervenes.")

    def pause(self, seconds):
        self.state["cooldown_until"] = max(
            self.state["cooldown_until"], time.time() + seconds
        )
        self.cache.clear()
        self.save()

    def transient_failure(self):
        self.state["failures"] = min(self.state["failures"] + 1, 6)
        self.pause(min(900 * 2 ** (self.state["failures"] - 1), 21600) + random.uniform(0, 60))

    def check(self):
        if self.state["halt_reason"]:
            raise PolicyError(self.state["halt_reason"] + " Owner intervention is required.")
        until = self.state["cooldown_until"]
        if until > time.time():
            raise PolicyError(f"X is cooling down; do not retry before Unix time {int(until) + 1}.")

    async def reserve(self):
        self.check()
        delay = self.state["next_request_at"] - time.time()
        if delay > 0:
            await asyncio.sleep(delay)
        self.check()
        now = time.time()
        self.state["requests"] = [t for t in self.state["requests"] if t > now - 86400]
        for seconds, limit in WINDOWS:
            recent = sorted(t for t in self.state["requests"] if t > now - seconds)
            if len(recent) >= limit:
                raise PolicyError(
                    f"X HTTP budget exhausted ({limit}/{seconds}s); "
                    f"do not retry before Unix time {int(recent[-limit] + seconds) + 1}."
                )
        # Reserve before sending, including failures, redirects and bootstrap assets.
        self.state["requests"].append(now)
        self.state["next_request_at"] = now + MIN_INTERVAL + random.uniform(0, JITTER)
        self.save()

    def status(self):
        now = time.time()
        return {
            "read_only": True,
            "http_budgets": [
                {"window_seconds": seconds, "limit": limit,
                 "used": sum(t > now - seconds for t in self.state["requests"])}
                for seconds, limit in WINDOWS
            ],
            "minimum_interval_seconds": MIN_INTERVAL,
            "jitter_seconds": JITTER,
            "next_request_at": self.state["next_request_at"],
            "cooldown_until": self.state["cooldown_until"],
            "halt_reason": self.state["halt_reason"],
            "cache_ttl_seconds": CACHE_TTL,
            "max_results": MAX_RESULTS,
        }


def get_policy():
    global _policy
    if _policy is None:
        try:
            _policy = Policy(Path(os.environ["TWIKIT_STATE_DIRECTORY"]))
        except Exception:
            raise PolicyError("X budget state is unavailable or already in use; refusing network access.") from None
    return _policy


class ReadOnlyTransport(httpx.AsyncBaseTransport):
    def __init__(self, policy, transport=None):
        self.policy = policy
        self.transport = transport if transport is not None else httpx.AsyncHTTPTransport(
            retries=0, trust_env=False, limits=httpx.Limits(max_connections=1)
        )

    async def handle_async_request(self, request):
        url = request.url
        base = str(url.copy_with(query=None))
        bootstrap = url.host == "x.com" and url.path in {"/", "/home"} and not url.query
        asset = (
            url.host == "abs.twimg.com" and not url.query
            and re.fullmatch(r"/responsive-web/client-web/ondemand\.s\.[a-f0-9]+a\.js", url.path)
        )
        read_get = request.method == "GET" and (base in READ_URLS - POST_READ_URLS or bootstrap or asset)
        read_post = request.method == "POST" and base in POST_READ_URLS
        if not (
            url.scheme == "https" and url.port in {None, 443}
            and not url.userinfo and (read_get or read_post)
        ):
            self.policy.halt("A request outside the read-only X allowlist was blocked.")
        if read_post:
            try:
                payload = json.loads(await request.aread())
                if not isinstance(payload, dict) or not payload.keys() <= {"queryId", "variables", "features"}:
                    raise ValueError("Unexpected GraphQL payload")
                if payload.get("queryId") != url.path.split("/")[-2]:
                    raise ValueError("GraphQL query does not match the allowed endpoint")
            except (ValueError, TypeError):
                self.policy.halt("A POST outside the allowed read-only GraphQL queries was blocked.")
        if asset:
            # httpx's hostless twikit cookies must never reach the static-asset host.
            for header in ("cookie", "authorization", "x-csrf-token"):
                request.headers.pop(header, None)
        async with self.policy.http_lock:
            await self.policy.reserve()
            try:
                response = await self.transport.handle_async_request(request)
                response.request = request
                await response.aread()
            except (httpx.HTTPError, OSError):
                self.policy.transient_failure()
                raise PolicyError("X HTTP request failed; a cooldown is active. No retry was sent.") from None
            except BaseException:
                self.policy.pause(900)
                raise
            finally:
                if "response" in locals():
                    await response.aclose()

            status = response.status_code
            try:
                data = response.json()
            except ValueError:
                data = None
            errors = data.get("errors", []) if isinstance(data, dict) else []
            codes = {e.get("code") for e in errors if isinstance(e, dict)} if isinstance(errors, list) else set()
            if status in {401, 403} or codes & {32, 37, 64, 89, 215, 326, 353}:
                self.policy.halt("X rejected authentication or reported an account/challenge restriction.")
            if status == 429 or 88 in codes:
                self.policy.transient_failure()
                self.policy.pause(max(3600, self.reset_delay(response.headers)) + random.uniform(0, 60))
                raise PolicyError("X rate limit reached; a persistent cooldown is active. No retry was sent.")
            if status >= 500 or status == 408:
                self.policy.transient_failure()
                raise PolicyError("X is unavailable; a persistent cooldown is active. No retry was sent.")
            if 300 <= status < 400:
                location = response.headers.get("location", "")
                target = url.join(location)
                if not location or target.host != "x.com" or target.path not in {"/", "/home"}:
                    self.policy.halt("X redirected to a login, challenge or unexpected location.")
            elif status >= 400 or errors or (base in READ_URLS and not isinstance(data, dict)):
                self.policy.halt("X returned an unexpected API response; inspection is required.")
            if bootstrap and any(marker in response.text.lower() for marker in (
                "cf-chl-", "verify you are human", "verify you're human", "<title>just a moment",
            )):
                self.policy.halt("X presented a browser challenge.")
            if response.headers.get("x-rate-limit-remaining") == "0":
                self.policy.pause(max(900, self.reset_delay(response.headers)) + random.uniform(0, 60))
            elif status == 200:
                if self.policy.state["failures"]:
                    self.policy.state["failures"] = 0
                    self.policy.save()
            return response

    @staticmethod
    def reset_delay(headers):
        delays = [0]
        try:
            delays.append(float(headers.get("x-rate-limit-reset", "0")) - time.time())
        except ValueError:
            pass
        retry = headers.get("retry-after", "0")
        try:
            delays.append(float(retry))
        except ValueError:
            try:
                delays.append(parsedate_to_datetime(retry).timestamp() - time.time())
            except (ValueError, TypeError, OverflowError):
                pass
        return max(delays)

    async def aclose(self):
        await self.transport.aclose()


async def create_client(language):
    policy = get_policy()
    policy.check()
    try:
        session = json.loads(Path(os.environ["TWIKIT_SESSION_FILE"]).read_text())
        for name in ("auth_token", "ct0", "user_agent"):
            if not isinstance(session[name], str) or not session[name].strip() or any(
                ord(c) < 32 or ord(c) > 126 for c in session[name]
            ):
                raise ValueError("Invalid session field")
    except Exception:
        raise PolicyError("X session file must contain auth_token, ct0 and the browser's user_agent.") from None
    client = Client(language=language, user_agent=session["user_agent"], trust_env=False)
    # Twikit's proxy setter installs its own HTTPX mounts even for proxy=None.
    # Replace that unused client so every request necessarily crosses our transport.
    await client.http.aclose()
    client.http = httpx.AsyncClient(
        transport=ReadOnlyTransport(policy), trust_env=False, timeout=30,
        follow_redirects=True, max_redirects=3,
    )
    client.set_cookies({"auth_token": session["auth_token"], "ct0": session["ct0"]})
    return client


def policy_tool(mcp):
    def decorate(function):
        if function.__name__ not in TOOLS:
            return function
        signature = inspect.signature(function, eval_str=True)

        @functools.wraps(function)
        async def guarded(*args, **kwargs):
            policy = get_policy()
            if function.__name__ == "rate_limit_status":
                return policy.status()
            bound = signature.bind(*args, **kwargs)
            bound.apply_defaults()
            count = bound.arguments.get("count", 1)
            if not 1 <= count <= MAX_RESULTS:
                raise PolicyError(f"count must be between 1 and {MAX_RESULTS}.")
            for key, value in bound.arguments.items():
                if isinstance(value, str) and len(value) > (2048 if key == "cursor" else 512):
                    raise PolicyError("X tool argument is too long.")
            async with policy.tool_lock:
                policy.check()
                cache_key = (function.__name__, json.dumps(bound.arguments, sort_keys=True))
                cached = policy.cache.get(cache_key)
                if cached and cached[0] > time.time():
                    policy.cache.move_to_end(cache_key)
                    return cached[1]
                try:
                    result = await function(*bound.args, **bound.kwargs)
                except PolicyError:
                    raise
                except Exception:
                    policy.transient_failure()
                    raise PolicyError("X read failed; a cooldown is active. No automatic retry was sent.") from None
                policy.cache[cache_key] = (time.time() + CACHE_TTL, result)
                if len(policy.cache) > 128:
                    policy.cache.popitem(last=False)
                return result

        guarded.__signature__ = signature
        guarded.__annotations__ = inspect.get_annotations(function, eval_str=True)
        description = (
            "Report persistent HTTP budgets, cooldown, halt state and cache settings without contacting X. "
            "These safety limits cannot be disabled through tool arguments or environment variables."
            if function.__name__ == "rate_limit_status"
            else (function.__doc__ or "") + "\nRead-only; at most 20 results per page. Results may be cached for 120 seconds."
        )
        mcp.tool(description=description, annotations=ToolAnnotations(
            readOnlyHint=True, destructiveHint=False, idempotentHint=True,
        ))(guarded)
        return guarded

    return decorate
