"""Authenticated, space-scoped Anytype v2 access for household agents."""

import argparse
import asyncio
import json
import re
from pathlib import Path

from fastmcp import Client
from fastmcp.client.transports import StdioTransport
from fastmcp.exceptions import ToolError
from fastmcp.server import create_proxy
from fastmcp.server.auth.providers.jwt import StaticTokenVerifier
from fastmcp.server.middleware import Middleware, MiddlewareContext
from fastmcp.server.transforms import ToolTransform
from fastmcp.tools.tool_transform import ArgTransformConfig, ToolTransformConfig


UNSCOPED_TOOLS = {
    "API-auth-whoami", "API-list-schemas", "API-get-schema", "API-get-op-schema",
    "API-validate",
}
EDIT_OPS = {"set_properties", "set_type", "update_block", "replace_text", "insert_blocks", "set_cell"}
BLOCK_FIELDS = {"text", "checked", "color", "backgroundColor", "language"}


class PolicyError(Exception):
    """A diagnostic containing only public tool/policy names and HTTP status codes."""


class HouseholdEdits(Middleware):
    async def on_call_tool(self, context: MiddlewareContext, call_next):
        args = context.message.arguments or {}
        if "space_id" in args:
            raise ToolError("The household space is configured by the bridge, not the caller.")
        if context.message.name == "API-patch-object":
            if not args.get("expected_etag"):
                raise ToolError("Read the object first and provide its expected_etag.")
            ops = args.get("ops")
            if not isinstance(ops, list) or not ops:
                raise ToolError("Provide a non-empty list of content edits.")
            for op in ops:
                if not isinstance(op, dict) or op.get("op") not in EDIT_OPS:
                    raise ToolError("Only content and object-type edits are allowed; no block deletion or view administration.")
                if op["op"] == "insert_blocks" and (
                    "blocks" in op or not isinstance(op.get("markdown"), str)
                ):
                    raise ToolError("Insert content using markdown, not structural blocks.")
                if op["op"] == "update_block" and (
                    not isinstance(op.get("set"), dict)
                    or not set(op["set"]) <= BLOCK_FIELDS
                ):
                    raise ToolError("Only text, checkbox and text-formatting fields may be updated.")
        return await call_next(context)


def household_proxy(name, transport, token, tools, space_id):
    proxy = create_proxy(
        # Negotiate upstream independently: Anytype's stdio server uses legacy MCP.
        Client(transport),
        name=f"{name}-anytype",
        auth=StaticTokenVerifier({token: {"client_id": name, "scopes": []}}),
        mask_error_details=True,
        strict_input_validation=True,
    )
    proxy.add_transform(ToolTransform({
        tool: ToolTransformConfig(arguments={
            "space_id": ArgTransformConfig(hide=True, default=space_id),
        })
        for tool in tools if tool not in UNSCOPED_TOOLS
    }))
    proxy.add_middleware(HouseholdEdits())
    proxy.enable(names=set(tools), components={"tool"}, only=True)
    return proxy


async def check_upstream(transport, tools, space_id):
    async with Client(transport) as client:
        available = {
            tool.name: tool.model_dump(by_alias=True)["inputSchema"]
            for tool in await client.list_tools()
        }
        missing = set(tools) - available.keys()
        if missing:
            raise PolicyError(f"Missing upstream tools: {', '.join(sorted(missing))}")
        for name in tools:
            if name not in UNSCOPED_TOOLS and "space_id" not in available[name].get("required", []):
                raise PolicyError(f"Tool must require space_id: {name}")
        patch_args = available["API-patch-object"].get("properties", {})
        if not {"expected_etag", "ops"} <= patch_args.keys():
            raise PolicyError("API-patch-object must support expected_etag and ops.")
        # Tool discovery is public; these calls must authenticate against the v2 account.
        for tool in ("API-get-space", "API-get-member-me"):
            try:
                await client.call_tool(tool, {"space_id": space_id})
            except ToolError as error:
                if "api key scope does not allow json api access" in str(error).lower():
                    raise PolicyError("HTTP 403: this key lacks JsonAPI scope; create a new JsonAPI key for the household space on the existing account.") from None
                status = re.search(r"\b(?:HTTP|status(?: code)?)[: ]+([45]\d{2})\b", str(error), re.IGNORECASE)
                detail = f" (HTTP {status[1]})" if status else ""
                raise PolicyError(f"Authenticated v2 access failed: {tool}{detail}; verify this account's API key and space grant.") from None


async def serve(args):
    token = args.token_file.read_text().strip()
    api_key = args.source_file.read_text().strip()
    space_id = args.space_file.read_text().strip()
    if len(token) < 32 or not api_key or not space_id:
        raise PolicyError("Configure a bridge token of at least 32 characters, an API key and a space ID.")
    tools = json.loads(args.policy_file.read_text())
    transport = StdioTransport(
        args.command,
        ["run", f"{args.api_url}/v2/docs/openapi.json"],
        keep_alive=True,
        env={
            "ANYTYPE_API_BASE_URL": args.api_url,
            "OPENAPI_MCP_HEADERS": json.dumps({"Authorization": f"Bearer {api_key}"}),
        },
    )
    try:
        await check_upstream(transport, tools, space_id)
        if args.check:
            print(f"{args.name} Anytype v2: authenticated space and member access; {len(tools)} tools verified.")
            return
        proxy = household_proxy(args.name, transport, token, tools, space_id)
        await proxy.run_async(
            transport="http", host="127.0.0.1", port=args.port,
            stateless_http=True, show_banner=False,
        )
    finally:
        await transport.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("name", choices=["frida", "alfred"])
    parser.add_argument("port", type=int)
    parser.add_argument("token_file", type=Path)
    parser.add_argument("policy_file", type=Path)
    parser.add_argument("source_file", type=Path)
    parser.add_argument("--space-file", type=Path, required=True)
    parser.add_argument("--command", required=True)
    parser.add_argument("--api-url", required=True)
    parser.add_argument("--check", action="store_true", help="Check authenticated v2 access and tool compatibility without starting HTTP.")
    args = parser.parse_args()
    try:
        asyncio.run(serve(args))
    except PolicyError as error:
        parser.exit(1, f"{args.name} Anytype MCP: {error}\n")
    except Exception as error:
        # Upstream errors may contain credentials or household document content.
        parser.exit(1, f"{args.name} Anytype MCP could not start ({type(error).__name__}); check the account, v2 key, space grant and upstream availability.\n")


if __name__ == "__main__":
    main()
