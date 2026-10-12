"""Authenticated household-only MCP proxies; upstream credentials stay on the host."""

import argparse
import asyncio
import json
from pathlib import Path

from fastmcp import Client
from fastmcp.client.transports import StdioTransport, StreamableHttpTransport
from fastmcp.exceptions import ToolError
from fastmcp.server import create_proxy
from fastmcp.server.auth.providers.jwt import StaticTokenVerifier
from fastmcp.server.middleware import Middleware, MiddlewareContext
from fastmcp.server.transforms import ToolTransform
from fastmcp.tools.tool_transform import ArgTransformConfig, ToolTransformConfig


HOUSEHOLD_SERVICES = {
    "light": {"turn_on", "turn_off", "toggle"},
    "switch": {"turn_on", "turn_off", "toggle"},
    "fan": {
        "turn_on", "turn_off", "toggle", "set_percentage", "set_preset_mode",
        "oscillate", "set_direction",
    },
    "climate": {
        "turn_on", "turn_off", "toggle", "set_temperature", "set_hvac_mode",
        "set_fan_mode", "set_preset_mode", "set_swing_mode", "set_humidity",
    },
    "cover": {
        "open_cover", "close_cover", "stop_cover", "toggle", "set_cover_position",
        "open_cover_tilt", "close_cover_tilt", "stop_cover_tilt", "set_cover_tilt_position",
    },
    "media_player": {
        "turn_on", "turn_off", "toggle", "media_play", "media_pause",
        "media_play_pause", "media_stop", "media_next_track", "media_previous_track",
        "volume_set", "volume_up", "volume_down", "volume_mute", "select_source",
        "play_media", "shuffle_set", "repeat_set",
    },
    "vacuum": {"start", "pause", "stop", "return_to_base", "locate", "set_fan_speed"},
    "humidifier": {"turn_on", "turn_off", "toggle", "set_humidity", "set_mode"},
    "input_boolean": {"turn_on", "turn_off", "toggle"},
    "input_number": {"set_value", "increment", "decrement"},
    "input_select": {
        "select_option", "select_next", "select_previous", "select_first", "select_last",
    },
    "scene": {"turn_on"},
}


class HouseholdControl(Middleware):
    async def on_call_tool(self, context: MiddlewareContext, call_next):
        if context.message.name == "ha_call_service":
            args = context.message.arguments or {}
            domain = args.get("domain")
            service = args.get("service")
            if (
                not isinstance(domain, str)
                or not isinstance(service, str)
                or service not in HOUSEHOLD_SERVICES.get(domain, set())
                or args.get("ws_command") is not None
            ):
                raise ToolError("Only household device services are allowed; no administration or raw WebSocket commands.")
        return await call_next(context)


def household_proxy(name, transport, token, tools, space_id=None):
    proxy = create_proxy(
        transport,
        name=f"frida-{name}",
        auth=StaticTokenVerifier({token: {"client_id": "frida", "scopes": []}}),
        mask_error_details=True,
        strict_input_validation=True,
    )
    if name == "anytype":
        proxy.add_transform(ToolTransform({
            tool: ToolTransformConfig(arguments={
                "space_id": ArgTransformConfig(hide=True, default=space_id),
            })
            for tool in tools
        }))
    else:
        proxy.add_middleware(HouseholdControl())
    # Also blocks direct calls to hidden tools and hides upstream resources/prompts.
    proxy.enable(names=set(tools), components={"tool"}, only=True)
    return proxy


async def serve(args):
    token = args.token_file.read_text().strip()
    if len(token) < 32:
        raise ValueError("Frida MCP token must have at least 32 characters")
    tools = json.loads(args.policy_file.read_text())
    space_id = None
    source = args.source_file.read_text().strip()
    if args.name == "anytype":
        if not args.command or args.space_file is None:
            raise ValueError("Anytype requires a command and a space file")
        space_id = args.space_file.read_text().strip()
        if not source or not space_id:
            raise ValueError("Anytype credentials and space must be configured")
        transport = StdioTransport(args.command, [], keep_alive=True, env={
            "ANYTYPE_API_BASE_URL": "http://127.0.0.1:31012",
            "OPENAPI_MCP_HEADERS": json.dumps({
                "Authorization": f"Bearer {source}", "Anytype-Version": "2025-11-08",
            }),
        })
    else:
        transport = StreamableHttpTransport(source)

    async with Client(transport) as client:
        available = {tool.name: tool for tool in await client.list_tools()}
        for name in tools:
            if name not in available:
                raise ValueError("An allowed tool is missing from the upstream server")
            if args.name == "anytype":
                schema = available[name].inputSchema
                if "space_id" not in schema.get("required", []):
                    raise ValueError("Anytype tools must require a space ID")
    proxy = household_proxy(args.name, transport, token, tools, space_id)
    await proxy.run_async(
        transport="http", host="127.0.0.1", port=args.port,
        stateless_http=True, show_banner=False,
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("name", choices=["anytype", "home-assistant"])
    parser.add_argument("port", type=int)
    parser.add_argument("token_file", type=Path)
    parser.add_argument("policy_file", type=Path)
    parser.add_argument("source_file", type=Path)
    parser.add_argument("--space-file", type=Path)
    parser.add_argument("--command")
    args = parser.parse_args()
    try:
        asyncio.run(serve(args))
    except Exception:
        # A Home Assistant URL contains its credential; never log upstream exceptions.
        parser.exit(1, f"Frida {args.name} MCP could not start; check secrets, policy and upstream availability.\n")


if __name__ == "__main__":
    main()
