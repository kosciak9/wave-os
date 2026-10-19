"""Serves a stdio MCP server over Streamable HTTP on loopback, to the bearer token's holder only.

Usage: mcp-bridge.py [--inline-attachments <Gotenberg URL>] <name> <port> <token file> <command> [args...]

With --inline-attachments, binary resources in tool results, which Alfred cannot read, come back
as images or text, as Gmail attachments do.
"""

import base64
import logging
import mimetypes
import sys

from fastmcp.client.transports import StdioTransport
from fastmcp.server import create_proxy
from fastmcp.server.auth.providers.jwt import StaticTokenVerifier
from fastmcp.server.middleware import Middleware
from fastmcp.tools import ToolResult
from mcp.types import BlobResourceContents, EmbeddedResource, TextContent


class InlineAttachments(Middleware):
    def __init__(self, gotenberg_url):
        self.gotenberg_url = gotenberg_url

    async def on_call_tool(self, context, call_next):
        from alfred_attachments import attachment_content

        result = await call_next(context)
        content = []
        for block in result.content:
            if not (isinstance(block, EmbeddedResource) and isinstance(block.resource, BlobResourceContents)):
                content.append(block)
                continue
            filename = (block.meta or {}).get("filename")
            mime_type = block.resource.mimeType or mimetypes.guess_type(filename or "")[0] or ""
            content.append(TextContent(type="text", text=f"Attachment {filename or block.resource.uri} ({mime_type or 'unknown type'}):"))
            try:
                data = base64.b64decode(block.resource.blob)
                content.extend(await attachment_content(data, filename, mime_type, self.gotenberg_url))
            except Exception:
                logging.exception("Could not read the attachment")
                content.append(TextContent(type="text", text="The attachment could not be read."))
        return ToolResult(content=content, structured_content=result.structured_content, meta=result.meta)


def main():
    arguments = sys.argv[1:]
    gotenberg_url = None
    if arguments[0] == "--inline-attachments":
        gotenberg_url, arguments = arguments[1], arguments[2:]
    name, port, token_file, command, *args = arguments
    with open(token_file, encoding="ascii") as source:
        token = source.read().strip()
    if len(token) < 32:
        sys.exit(f"{token_file} holds no token")
    proxy = create_proxy(
        StdioTransport(command, args, keep_alive=True),
        name=name,
        auth=StaticTokenVerifier({token: {"client_id": "alfred", "scopes": []}}),
    )
    if gotenberg_url:
        proxy.add_middleware(InlineAttachments(gotenberg_url))
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
