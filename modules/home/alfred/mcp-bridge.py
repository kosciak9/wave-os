"""Serves a stdio MCP server over Streamable HTTP on loopback, to the bearer token's holder only.

Usage: mcp-bridge.py [--inline-attachments <Gotenberg URL> <Whisper URL>] [--start-now] <name> <port> <token file> <command> [args...]

With --inline-attachments, every binary resource in a tool result is followed by a preview Alfred's
model reads (images, text or a transcript, as for Gmail attachments); the resource itself stays, so
a script can pass the original bytes on.

The server starts at the first call, and then keeps running; --start-now starts it with the bridge
and restarts it within a minute after it exits, for a server that has to stay connected even while
nobody calls it.
"""

import base64
import contextlib
import logging
import mimetypes
import os
import sys

import anyio
from fastmcp.client.transports import StdioTransport
from fastmcp.server import create_proxy
from fastmcp.server.providers.proxy import FastMCPProxy, ProxyClient
from fastmcp.server.auth.providers.jwt import StaticTokenVerifier
from fastmcp.server.middleware import Middleware
from fastmcp.tools import ToolResult
from mcp.types import BlobResourceContents, EmbeddedResource, TextContent


class InlineAttachments(Middleware):
    def __init__(self, gotenberg_url, whisper_url):
        self.gotenberg_url = gotenberg_url
        self.whisper_url = whisper_url

    async def on_call_tool(self, context, call_next):
        from alfred_attachments import preview

        result = await call_next(context)
        content = []
        for block in result.content:
            content.append(block)
            if not (isinstance(block, EmbeddedResource) and isinstance(block.resource, BlobResourceContents)):
                continue
            filename = (block.meta or {}).get("filename")
            mime_type = block.resource.mimeType or ""
            if mime_type in ("", "application/octet-stream"):
                mime_type = mimetypes.guess_type(filename or "")[0] or mime_type
            try:
                data = base64.b64decode(block.resource.blob, validate=True)
            except ValueError:
                logging.exception("The attachment is not base64")
                content.append(TextContent(type="text", text="The attachment could not be previewed."))
                continue
            content.extend(
                await preview(data, filename or block.resource.uri, mime_type, self.gotenberg_url, self.whisper_url)
            )
        return ToolResult(
            content=content, structured_content=result.structured_content, meta=result.meta, is_error=result.is_error
        )


def main():
    arguments = sys.argv[1:]
    gotenberg_url = whisper_url = None
    if arguments[0] == "--inline-attachments":
        gotenberg_url, whisper_url, arguments = arguments[1], arguments[2], arguments[3:]
    start_now = arguments[0] == "--start-now"
    if start_now:
        arguments = arguments[1:]
    name, port, token_file, command, *args = arguments
    with open(token_file, encoding="ascii") as source:
        token = source.read().strip()
    if len(token) < 32:
        sys.exit(f"{token_file} holds no token")
    # The service's own environment, not the MCP client's minimal default: rootless Podman finds
    # its runtime directory and the user's systemd through XDG_RUNTIME_DIR and the session bus.
    transport = StdioTransport(command, args, env=dict(os.environ), keep_alive=True)
    auth = StaticTokenVerifier({token: {"client_id": "alfred", "scopes": []}})
    if start_now:
        # A session with other options makes the transport restart the server, and
        # create_proxy's clients take each caller's protocol era. Copies of one client keep
        # the server that starts here for every call.
        backend = ProxyClient(transport)

        async def ping():
            # A session on a server that has exited starts it again.
            while True:
                await anyio.sleep(60)
                try:
                    async with backend.new() as client:
                        await client.ping()
                except Exception:
                    logging.exception("%s did not answer", name)

        @contextlib.asynccontextmanager
        async def start(server):
            # A server that cannot start stops the bridge, for systemd to retry; keep_alive
            # leaves it running for the proxy's sessions.
            async with backend.new():
                pass
            async with anyio.create_task_group() as tasks:
                tasks.start_soon(ping)
                yield {}
                tasks.cancel_scope.cancel()

        proxy = FastMCPProxy(client_factory=backend.new, name=name, auth=auth, lifespan=start)
    else:
        proxy = create_proxy(transport, name=name, auth=auth)
    if gotenberg_url:
        proxy.add_middleware(InlineAttachments(gotenberg_url, whisper_url))
    # Stateless, so a client keeps working across restarts of the bridge.
    proxy.run(
        transport="http",
        host="127.0.0.1",
        port=int(port),
        stateless_http=True,
        show_banner=False,
    )


if __name__ == "__main__":
    main()
