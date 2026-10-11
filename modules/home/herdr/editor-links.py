import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
from urllib.parse import parse_qsl, unquote, urlsplit


def editor_target(uri):
    if (
        not uri.startswith("herdr-edit:///")
        or len(uri.encode("utf-8")) > 8192
        or re.search(r"[\x00-\x20\x7f]|%(?![0-9a-fA-F]{2})", uri)
    ):
        raise ValueError("Invalid editor link")
    url = urlsplit(uri)
    if url.netloc or url.fragment:
        raise ValueError("Editor links must name a file on the session host")
    path = unquote(url.path, errors="strict")
    if (
        not path.startswith("/")
        or path.startswith("//")
        or re.search(r"[\x00-\x1f\x7f]", path)
        or Path(path).is_relative_to("/net")
    ):
        raise ValueError("Invalid editor file path")
    # Resolve symlinks before checking /net so an editor cannot trigger an automount.
    resolved = Path("/")
    pending = list(reversed(Path(path).parts[1:]))
    links = 0
    while pending:
        part = pending.pop()
        resolved = resolved.parent if part == ".." else resolved / part
        if resolved.is_relative_to("/net"):
            raise ValueError("Network paths are not supported")
        if resolved.is_symlink():
            links += 1
            if links > 40:
                raise ValueError("Too many file symlinks")
            target = resolved.readlink()
            resolved = Path("/") if target.is_absolute() else resolved.parent
            pending.extend(reversed(target.parts[1:] if target.is_absolute() else target.parts))
    if not resolved.is_file():
        raise ValueError("Editor link does not name an existing regular file")
    position = {"line": 1, "column": 1}
    seen = set()
    parameters = parse_qsl(
        url.query, keep_blank_values=True, strict_parsing=True, max_num_fields=2
    )
    for key, value in parameters:
        if key not in position or key in seen or not re.fullmatch(r"[0-9]{1,10}", value):
            raise ValueError("Expected unique numeric line and column parameters")
        number = int(value)
        if not 1 <= number <= 2147483647:
            raise ValueError("Editor position is out of range")
        position[key] = number
        seen.add(key)
    return str(resolved), position["line"], position["column"]


def request(method, params):
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(10)
        client.connect(os.environ["HERDR_SOCKET_PATH"])
        payload = {"id": "herdr-editor-links", "method": method, "params": params}
        client.sendall((json.dumps(payload) + "\n").encode("utf-8"))
        with client.makefile("rb") as stream:
            response = json.loads(stream.readline(1024 * 1024))
    if response.get("error"):
        raise ValueError(response["error"]["message"])
    return response["result"]


def main():
    mode = sys.argv[1]
    uri = os.environ.get(
        "HERDR_PLUGIN_CLICKED_URL" if mode == "open" else "HERDR_EDITOR_URI", ""
    )
    path, line, column = editor_target(uri)
    # Only the validated numbers enter Ex commands; the filename remains an argv item.
    arguments = [
        "--cmd",
        "set nomodeline noexrc",
        "-c",
        f"call cursor({line}, {column})",
    ]
    if mode == "terminal":
        os.execv(sys.argv[2], [sys.argv[2], *arguments, "--", path])
    elif mode == "open" and sys.argv[2] == "gui":
        # The daemon may predate the desktop session; use the user manager's GUI environment.
        subprocess.run(
            [
                sys.argv[3],
                "--user",
                "--collect",
                "--quiet",
                "--service-type=exec",
                "--",
                sys.argv[4],
                "--no-fork",
                "--neovim-bin",
                sys.argv[5],
                # Neovide inserts --embed before its own file targets.
                path,
                "--",
                *arguments,
            ],
            check=True,
        )
    elif mode == "open" and sys.argv[2] == "split":
        context = json.loads(os.environ["HERDR_PLUGIN_CONTEXT_JSON"])
        request(
            "plugin.pane.open",
            {
                "plugin_id": "herdr.editor-links",
                "entrypoint": "editor",
                "placement": "split",
                "target_pane_id": context["focused_pane_id"],
                "direction": "right",
                "cwd": str(Path(path).parent),
                "focus": True,
                "env": {"HERDR_EDITOR_URI": uri},
            },
        )
    else:
        raise ValueError("Invalid editor invocation")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        message = str(error)
        print(f"Editor link failed: {message}", file=sys.stderr)
        if sys.argv[1:2] == ["open"] and os.environ.get("HERDR_SOCKET_PATH"):
            try:
                request("notification.show", {"title": "Editor link failed", "body": message})
            except (ValueError, OSError, KeyError) as notification_error:
                print(f"Cannot show editor error: {notification_error}", file=sys.stderr)
        sys.exit(1)
