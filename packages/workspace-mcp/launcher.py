import json
import logging
import os
import sys

from fastmcp.exceptions import ToolError
from fastmcp.server.middleware import Middleware


class WorkspacePolicy(Middleware):
    def __init__(self, allowed_tools, email):
        self.allowed_tools = frozenset(allowed_tools)
        self.email = email

    async def on_list_tools(self, context, call_next):
        tools = await call_next(context)
        allowed = []
        for tool in tools:
            if tool.name not in self.allowed_tools:
                continue
            schema = dict(tool.parameters)
            properties = dict(schema["properties"])
            description = tool.description
            if tool.name == "manage_event":
                properties["action"] = {
                    **properties["action"],
                    "enum": ["create", "update"],
                    "description": "Create or update an event; deletion and RSVP are prohibited.",
                }
                description = "Create or update a Google Calendar event. Deletion and RSVP are not permitted."
            elif tool.name == "modify_gmail_message_labels":
                description = "Change inbox, unread, starred or important status of one Gmail message. Removing INBOX archives it; trash, spam and custom-label changes are prohibited."
                for key in ("add_label_ids", "remove_label_ids"):
                    properties[key] = {
                        "type": "array",
                        "items": {"type": "string", "enum": ["INBOX", "UNREAD", "STARRED", "IMPORTANT"]},
                        "description": "System-label IDs to add or remove.",
                    }
            elif tool.name == "draft_gmail_message":
                description = "Create a text or HTML Gmail draft, optionally as a reply. Does not send mail or read host files, attachment URLs or account signatures."
                for key in ("attachments", "from_email", "include_signature"):
                    properties.pop(key, None)
            if "full" in properties:
                properties["full"] = {
                    **properties["full"],
                    "enum": [False],
                    "default": False,
                    "description": "Only inline message reads are available; host-file export is disabled.",
                }
            schema["properties"] = properties
            tool = tool.model_copy(update={"parameters": schema, "description": description})
            allowed.append(tool)
        return allowed

    async def on_call_tool(self, context, call_next):
        name = context.message.name
        if name not in self.allowed_tools:
            raise ToolError("Tool is not permitted by the Workspace MCP policy.")
        arguments = dict(context.message.arguments or {})
        if "userGoogleEmail" in arguments:
            if arguments.pop("userGoogleEmail") != self.email:
                raise ToolError("Only the configured Google account is permitted.")
        if arguments.get("user_google_email", self.email) != self.email:
            raise ToolError("Only the configured Google account is permitted.")
        arguments["user_google_email"] = self.email
        if arguments.get("full") not in (None, False):
            raise ToolError("Use inline message reads; host-file export is not available to the sandbox.")

        if name == "manage_event":
            if not isinstance(arguments.get("action"), str) or arguments["action"] not in {"create", "update"}:
                raise ToolError("Only calendar event creation and updates are permitted.")
            if arguments["action"] == "update" and not arguments.get("event_id"):
                raise ToolError("Updating a calendar event requires its event ID.")
        elif name == "modify_gmail_message_labels":
            # Gmail represents read/star flags and archiving as system-label changes.
            permitted_labels = {"INBOX", "UNREAD", "STARRED", "IMPORTANT"}
            for key in ("add_label_ids", "remove_label_ids"):
                labels = arguments.get(key)
                if labels is None:
                    continue
                if isinstance(labels, str):
                    try:
                        labels = json.loads(labels)
                    except ValueError:
                        raise ToolError("Label changes must be a list of system-label IDs.") from None
                if not isinstance(labels, list) or any(
                    not isinstance(label, str) or label not in permitted_labels
                    for label in labels
                ):
                    raise ToolError("Only inbox, read, star and importance flags may be changed.")
                arguments[key] = labels
        elif name == "draft_gmail_message":
            # The upstream draft tool can read server-side paths for attachments.
            if arguments.get("attachments"):
                raise ToolError("Reading host files or URLs for draft attachments is not permitted.")
            if arguments.get("from_email") not in (None, "", self.email):
                raise ToolError("Drafts must use the configured Google account.")
            arguments["include_signature"] = False

        context = context.copy(
            message=context.message.model_copy(update={"arguments": arguments})
        )
        return await call_next(context)


def main():
    with open(sys.argv[1], encoding="utf-8") as policy_file:
        policy = json.load(policy_file)
    email = os.environ["USER_GOOGLE_EMAIL"]

    logging.basicConfig(level=logging.WARNING)
    logging.getLogger().setLevel(logging.WARNING)
    import main as upstream

    upstream.server.add_middleware(WorkspacePolicy(policy["allowedTools"], email))
    sys.argv = [
        "workspace-mcp",
        "--transport", "stdio",
        "--permissions", "gmail:drafts", "calendar:full",
    ]
    upstream.main()


if __name__ == "__main__":
    main()
