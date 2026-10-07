"""Serves a stdio MCP server over Streamable HTTP on loopback, to the bearer token's holder only.

Usage: mcp-bridge.py <name> <port> <token file> <command> [args...]
"""

import sys

from fastmcp.client.transports import StdioTransport
from fastmcp.server import create_proxy
from fastmcp.server.auth.providers.jwt import StaticTokenVerifier


def main():
    name, port, token_file, command, *args = sys.argv[1:]
    with open(token_file, encoding="ascii") as source:
        token = source.read().strip()
    if len(token) < 32:
        sys.exit(f"{token_file} holds no token")
    proxy = create_proxy(
        StdioTransport(command, args, keep_alive=True),
        name=name,
        auth=StaticTokenVerifier({token: {"client_id": "alfred", "scopes": []}}),
    )
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
