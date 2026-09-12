#!/usr/bin/env python3
"""Small, dependency-free Camofox HTTP client."""

import argparse
import base64
import binascii
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qsl, urlencode, urljoin, urlsplit, urlunsplit
from urllib.request import Request, urlopen


DEFAULT_URL = "http://127.0.0.1:9377"


def die(message, code=2):
    """Print an error and terminate with the CLI error code."""
    print("camofox: " + message, file=sys.stderr)
    raise SystemExit(code)


def access_key():
    """Get the access key, preserving the existing local lookup order."""
    value = os.environ.get("CAMOFOX_ACCESS_KEY")
    if value:
        return value

    if shutil.which("openclaw"):
        try:
            result = subprocess.run(
                ["openclaw", "secrets", "store", "get", "CAMOFOX_ACCESS_KEY", "--plain"],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=10,
                check=False,
            )
            value = result.stdout.strip()
            if value:
                return value
        except (OSError, subprocess.SubprocessError):
            pass

    state = (
        pathlib.Path(os.environ.get("XDG_STATE_HOME", pathlib.Path.home() / ".local/state"))
        / "camofox/access-key"
    )
    try:
        value = state.read_text().strip()
    except OSError:
        value = ""
    if value:
        return value
    die(
        "no access key; set CAMOFOX_ACCESS_KEY, configure openclaw secrets, "
        "or create XDG_STATE_HOME/camofox/access-key"
    )


def state_path(user, session):
    root = pathlib.Path(
        os.environ.get("XDG_STATE_HOME", pathlib.Path.home() / ".local/state")
    ) / "camofox"
    key = hashlib.sha256((user + "\0" + session).encode()).hexdigest()
    return root / (key + ".json")


def validate_base_url(value):
    """Allow only an HTTP URL targeting the local machine."""
    parts = urlsplit("")
    hostname = None
    try:
        parts = urlsplit(value)
        hostname = parts.hostname
        parts.port  # Validate malformed ports as well as the hostname.
    except ValueError:
        die("base URL must be HTTP on localhost, 127.0.0.1, or [::1] without credentials or fragments")
    if (
        parts.scheme.lower() != "http"
        or not parts.netloc
        or not hostname
        or parts.username is not None
        or parts.password is not None
        or parts.fragment
        or hostname.lower() not in ("localhost", "127.0.0.1", "::1")
    ):
        die("base URL must be HTTP on localhost, 127.0.0.1, or [::1] without credentials or fragments")
    return value.rstrip("/")


def load_tab(user, session):
    try:
        data = json.loads(state_path(user, session).read_text())
        return data.get("tabId")
    except (OSError, ValueError, AttributeError):
        return None


def save_tab(user, session, tab):
    path = state_path(user, session)
    temporary = None
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        descriptor, temporary_name = tempfile.mkstemp(
            dir=path.parent, prefix="." + path.name + ".", suffix=".tmp"
        )
        temporary = pathlib.Path(temporary_name)
        with os.fdopen(descriptor, "w") as stream:
            stream.write(json.dumps({"tabId": tab}) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
        temporary = None
    except OSError as error:
        if temporary is not None:
            try:
                temporary.unlink()
            except OSError:
                pass
        die("cannot save current tab: " + str(error))


def _without_secret(message, secret):
    """Prevent a server response or exception from reflecting the access key."""
    return message.replace(secret, "[redacted]") if secret else message


def _origin_relative_path(path):
    """Return a path that cannot make urljoin leave the configured origin."""
    # urljoin treats both network-path references (//host/path) and URLs with
    # schemes as authoritative URLs.  API paths must never have that meaning.
    if not path or path.startswith("//"):
        die("API path must be origin-relative (not an absolute URL)")
    parts = urlsplit(path)
    if parts.scheme or parts.netloc:
        die("API path must be origin-relative (not an absolute URL)")
    return path if path.startswith("/") else "/" + path


def request(args, method, path, body=None, authenticate=True):
    path = _origin_relative_path(path)
    url = urljoin(args.base_url.rstrip("/") + "/", path.lstrip("/"))

    # Camofox accepts userId in the query for both collection and tab routes.
    # Apply it to generic API calls too, while respecting an explicit value.
    parts = urlsplit(url)
    query = dict(parse_qsl(parts.query, keep_blank_values=True))
    query.setdefault("userId", args.user)
    url = urlunsplit(
        (parts.scheme, parts.netloc, parts.path, urlencode(query), parts.fragment)
    )

    request_body = body
    if isinstance(request_body, dict) and "userId" not in request_body and method not in (
        "GET",
        "HEAD",
    ):
        request_body = {**request_body, "userId": args.user}
    data = None if request_body is None else json.dumps(request_body).encode()
    headers = {
        "Accept": "application/json, application/octet-stream",
        "User-Agent": "camofox-cli/1",
    }
    secret = None
    if authenticate:
        secret = access_key()
        assert secret is not None
        headers["Authorization"] = "Bearer " + secret
    if data is not None:
        headers["Content-Type"] = "application/json"

    try:
        with urlopen(
            Request(url, data=data, headers=headers, method=method), timeout=args.timeout
        ) as response:
            return response.status, response.read(), response.headers.get_content_type()
    except HTTPError as error:
        raw = error.read(4096)
        try:
            detail = json.loads(raw).get("error", raw.decode(errors="replace"))
        except (ValueError, AttributeError, TypeError):
            detail = raw.decode(errors="replace")
        die(_without_secret(str(detail).strip(), secret))
    except (URLError, TimeoutError, OSError) as error:
        die(_without_secret("request failed: " + str(getattr(error, "reason", error)), secret))


def _screenshot_bytes(raw):
    """Extract screenshot bytes from either raw output or common JSON envelopes."""
    try:
        value = json.loads(raw)
    except (UnicodeDecodeError, ValueError):
        return raw
    if not isinstance(value, dict):
        return raw
    image = value.get("screenshot")
    encoded = image.get("data") if isinstance(image, dict) else image
    if not isinstance(encoded, str):
        return raw
    try:
        return base64.b64decode(encoded, validate=True)
    except (binascii.Error, ValueError):
        return raw


def output(args, raw, content_type):
    if args.output:
        try:
            pathlib.Path(args.output).write_bytes(_screenshot_bytes(raw))
        except OSError as error:
            die("cannot write output: " + str(error))
        return

    if content_type in ("application/json", "text/json") or raw[:1] in (b"{", b"["):
        try:
            print(json.dumps(json.loads(raw), indent=2, ensure_ascii=False))
            return
        except (UnicodeDecodeError, ValueError):
            pass
    # Never write arbitrary binary to stdout.
    print(json.dumps({"data": base64.b64encode(raw).decode(), "contentType": content_type}))


def tab(args):
    value = args.tab or load_tab(args.user, args.session)
    if not value:
        die("no current tab; use 'open URL' or --tab TAB_ID")
    return value


def main():
    parser = argparse.ArgumentParser(prog="camofox")
    parser.add_argument("--base-url", "-b", default=os.environ.get("CAMOFOX_BASE_URL", DEFAULT_URL))
    parser.add_argument("--user", "--user-id", default=os.environ.get("CAMOFOX_USER_ID", "opencode"))
    parser.add_argument(
        "--session", "--session-key", default=os.environ.get("CAMOFOX_SESSION_KEY", "opencode")
    )
    parser.add_argument("--tab", help="tab ID (otherwise use persisted current tab)")
    parser.add_argument("--timeout", type=float, default=30)
    parser.add_argument("--output", "-o", help="write response bytes to a file")
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("health")
    subparsers.add_parser("tabs")
    command = subparsers.add_parser("open")
    command.add_argument("url")
    command = subparsers.add_parser("navigate")
    command.add_argument("url")
    subparsers.add_parser("snapshot")
    command = subparsers.add_parser("click")
    command.add_argument("target", help="snapshot ref or CSS selector")
    command.add_argument("--selector", action="store_true")
    command = subparsers.add_parser("type")
    command.add_argument("text")
    command.add_argument("--ref")
    command.add_argument("--selector")
    command = subparsers.add_parser("press")
    command.add_argument("key")
    command = subparsers.add_parser("scroll")
    command.add_argument("direction", nargs="?", default="down", choices=["up", "down", "left", "right"])
    command.add_argument("--amount", type=int)
    command = subparsers.add_parser("eval")
    command.add_argument("expression")
    command = subparsers.add_parser("screenshot")
    command.add_argument("--full-page", action="store_true")
    subparsers.add_parser("close")
    command = subparsers.add_parser("api")
    command.add_argument("method", type=str.upper, choices=["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"])
    command.add_argument("path")
    command.add_argument("json", nargs="?")
    for command in subparsers.choices.values():
        command.add_argument("--tab", default=argparse.SUPPRESS, help=argparse.SUPPRESS)

    args = parser.parse_args()
    args.base_url = validate_base_url(args.base_url)
    command = args.command
    if command == "health":
        _, raw, content_type = request(args, "GET", "/health", authenticate=False)
    elif command == "tabs":
        _, raw, content_type = request(args, "GET", "/tabs")
    elif command == "open":
        _, raw, content_type = request(
            args, "POST", "/tabs", {"userId": args.user, "sessionKey": args.session, "url": args.url}
        )
        try:
            save_tab(args.user, args.session, json.loads(raw)["tabId"])
        except (ValueError, KeyError, TypeError):
            pass
    elif command == "api":
        body = None
        if args.json:
            source = (
                sys.stdin.read()
                if args.json == "-"
                else pathlib.Path(args.json[1:]).read_text()
                if args.json.startswith("@")
                else args.json
            )
            try:
                body = json.loads(source)
            except (TypeError, ValueError) as error:
                die("invalid JSON body: " + str(error))
        _, raw, content_type = request(args, args.method, args.path, body)
    else:
        current_tab = tab(args)
        assert current_tab is not None
        path = "/tabs/" + current_tab
        if command == "navigate":
            method, body, path = "POST", {"url": args.url}, path + "/navigate"
        elif command == "snapshot":
            method, body, path = "GET", None, path + "/snapshot"
        elif command == "click":
            method, body, path = "POST", {"selector" if args.selector else "ref": args.target}, path + "/click"
        elif command == "type":
            method, body, path = "POST", {"text": args.text}, path + "/type"
            if getattr(args, "ref", None):
                body["ref"] = args.ref
            if getattr(args, "selector", None):
                body["selector"] = args.selector
        elif command == "press":
            method, body, path = "POST", {"key": args.key}, path + "/press"
        elif command == "scroll":
            method, body, path = "POST", {"direction": args.direction}, path + "/scroll"
            if args.amount is not None:
                body["amount"] = args.amount
        elif command == "eval":
            method, body, path = "POST", {"expression": args.expression}, path + "/evaluate"
        elif command == "screenshot":
            method, body, path = "GET", None, path + "/screenshot"
            if args.full_page:
                path += "?fullPage=true"
        else:  # close
            method, body = "DELETE", None
        _, raw, content_type = request(args, method, path, body)
        if command == "close":
            if args.tab is None or load_tab(args.user, args.session) == current_tab:
                try:
                    state_path(args.user, args.session).unlink()
                except OSError:
                    pass
    output(args, raw, content_type)


if __name__ == "__main__":
    main()
