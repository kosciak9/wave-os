"""A stdio MCP server of ephemeral sandboxes: containers that live until they sit idle for their TTL.

Usage: sandbox.py <Podman connection> <image> <volume>
"""

import asyncio
import secrets
import sys
from typing import Annotated

from fastmcp import FastMCP
from fastmcp.exceptions import ToolError
from pydantic import Field

connection, image, volume = sys.argv[1:]
mcp = FastMCP("sandbox")
LABEL = "io.wave-os.component=alfred-sandbox"
PREFIX = "wave-alfred-sandbox-"
OUTPUT_LIMIT = 50_000

# The sandbox expires itself: its first process exits, and --rm removes it, once /tmp/alive is
# older than the TTL. A command pushes that time past its own timeout while it runs, so the
# sandbox outlives it, and touches it again when done.
WATCHDOG = 'touch /tmp/alive; while (( $(date +%s) - $(stat -c %Y /tmp/alive) < TTL )); do sleep 15; done'
COMMAND = 'touch -d "@$(( $(date +%s) + TIMEOUT + 60 ))" /tmp/alive; timeout --kill-after=10 "$TIMEOUT" bash -c "$1"; status=$?; touch /tmp/alive; exit $status'

# Sandboxes this server started whose network rules are in place, by name, with their container
# IDs. Commands run only in these; the others, from before a restart, are removed at start.
ready = {}


async def podman(*args):
    process = await asyncio.create_subprocess_exec(
        "podman", "--connection", connection, *args,
        stdin=asyncio.subprocess.DEVNULL,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
    )
    output, _ = await process.communicate()
    return process.returncode, output.decode(errors="replace")


def sandbox_container(sandbox):
    if sandbox not in ready:
        raise ToolError(f"{sandbox!r} is no sandbox of this server; create one")
    return ready[sandbox]


@mcp.tool
async def create(ttl_minutes: Annotated[int, Field(ge=1, le=1440)] = 30) -> str:
    """Start a sandbox, a Debian container with Python 3 and internet access; returns its name.

    It reaches nothing local: not the host, the LAN, the tailnet or other containers.

    It is removed with everything in it once no command has run in it for `ttl_minutes`, except
    /workspace, which every sandbox shares and which persists. /skills holds read-only skills,
    e.g. /skills/unbroker.
    """
    name = PREFIX + secrets.token_hex(4)
    status, output = await podman(
        "run", "--detach", "--rm", "--pull", "never", "--name", name, "--label", LABEL,
        "--network", "bridge", "--http-proxy=false",
        "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
        "--pids-limit", "256", "--memory", "2g", "--cpus", "2",
        "--volume", f"{volume}:/workspace:rw,Z", "--workdir", "/workspace", "--env", "HOME=/workspace",
        "--env", f"TTL={ttl_minutes * 60}", image, "bash", "-c", WATCHDOG,
    )
    if status != 0:
        raise ToolError(output)
    container = output.strip()
    # The sandbox has no capabilities to change these rules, and no command runs in it before they
    # are in place. Without them, also when the call is cancelled, it is removed.
    firewall_output = "the call was cancelled"
    restricted = False
    try:
        status, firewall_output = await podman(
            "run", "--rm", "--pull", "never", "--network", f"container:{container}", "--label", LABEL,
            "--cap-drop", "ALL", "--cap-add", "NET_ADMIN", "--security-opt", "no-new-privileges",
            image, "nft", "-f", "/etc/sandbox.nft",
        )
        restricted = status == 0
    finally:
        if not restricted:
            removed, removal_output = await podman("rm", "--force", "--time", "0", container)
    if not restricted:
        outcome = "it was removed" if removed == 0 else f"removing it failed too:\n{removal_output}"
        raise ToolError(f"The sandbox's network could not be restricted ({firewall_output.strip()}); {outcome}")
    ready[name] = container
    return name


@mcp.tool
async def run(
    sandbox: str,
    command: str,
    timeout_seconds: Annotated[int, Field(ge=1, le=1800)] = 600,
) -> str:
    """Run `command` with bash in a sandbox, in /workspace.

    Files stay for the sandbox's next commands; the working directory and environment do not.
    Returns the exit status (124 after the timeout) and the combined output, only its end when it
    is longer than 50,000 characters.
    """
    status, output = await podman(
        "exec", "--env", f"TIMEOUT={timeout_seconds}", sandbox_container(sandbox),
        "bash", "-c", COMMAND, "bash", command,
    )
    if len(output) > OUTPUT_LIMIT:
        output = f"[first {len(output) - OUTPUT_LIMIT} characters left out]\n{output[-OUTPUT_LIMIT:]}"
    return f"exit status {status}\n{output}"


@mcp.tool
async def list_sandboxes() -> str:
    """The sandboxes still alive, with when each was created."""
    status, output = await podman(
        "ps", "--filter", f"label={LABEL}", "--format", "{{.Names}} {{.CreatedHuman}}"
    )
    if status != 0:
        raise ToolError(output)
    alive = [line for line in output.splitlines() if line.split(" ", 1)[0] in ready]
    return "\n".join(alive) or "No sandboxes."


@mcp.tool
async def close(sandbox: str) -> str:
    """Remove a sandbox now, with everything in it but /workspace."""
    status, output = await podman("rm", "--force", "--time", "0", sandbox_container(sandbox))
    if status != 0:
        raise ToolError(output)
    del ready[sandbox]
    return f"Removed {sandbox}."


if __name__ == "__main__":
    status, output = asyncio.run(podman("rm", "--force", "--time", "0", "--filter", f"label={LABEL}"))
    if status != 0:
        sys.exit(f"Could not remove the sandboxes of an earlier server:\n{output}")
    mcp.run(show_banner=False)
