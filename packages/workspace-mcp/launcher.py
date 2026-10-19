import json
import logging
import mimetypes
import os
import re
import sys
from pathlib import Path

from fastmcp.exceptions import ToolError
from fastmcp.server.middleware import Middleware
from fastmcp.tools import ToolResult
from mcp.types import TextContent

from alfred_attachments import MAX_PDF_PAGES, MAX_TEXT_CHARS, attachment_content


def mail_attachments(attachments):
    """Only base64 content: upstream mail tools also read host paths and fetch URLs."""
    import base64
    import binascii

    if isinstance(attachments, str):
        try:
            attachments = json.loads(attachments)
        except ValueError:
            raise ToolError("Mail attachments must be a list of files.") from None
    if not isinstance(attachments, list):
        raise ToolError("Mail attachments must be a list of files.")
    for attachment in attachments:
        if not isinstance(attachment, dict) or not attachment.keys() <= {"content", "filename", "mime_type"}:
            raise ToolError("Mail attachments may only carry base64 content, a file name and a MIME type; host files and URLs are not permitted.")
        content, filename = attachment.get("content"), attachment.get("filename")
        mime_type = attachment.get("mime_type")
        if not isinstance(content, str) or not content or not isinstance(filename, str) or not filename:
            raise ToolError("Every mail attachment needs base64 content and a file name.")
        if mime_type is not None and not isinstance(mime_type, str):
            raise ToolError("A mail attachment's MIME type must be a string.")
        try:
            base64.b64decode(content, validate=True)
        except binascii.Error:
            raise ToolError(f"The content of {filename} is not standard base64.") from None
    return attachments


class WorkspacePolicy(Middleware):
    def __init__(self, allowed_tools, email, inline_attachments=False, gotenberg_url=None):
        self.allowed_tools = frozenset(allowed_tools)
        self.email = email
        # Attachments come back as their content, for clients that cannot read the host's files.
        self.inline_attachments = inline_attachments
        self.gotenberg_url = gotenberg_url

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
            elif tool.name in {"draft_gmail_message", "send_gmail_message"}:
                action = "Create a Gmail draft" if tool.name == "draft_gmail_message" else "Send a Gmail message only when the user requests sending"
                description = f"{action}, optionally as a reply, with attachments passed as base64 content. Does not read host files, attachment URLs or account signatures. Use file_read inside codemode to attach an exported local file; do not copy file bytes through model context."
                for key in ("from_email", "include_signature"):
                    properties.pop(key, None)
                properties["attachments"] = {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "content": {"type": "string", "description": "The file's bytes as standard base64, not URL-safe."},
                            "filename": {"type": "string"},
                            "mime_type": {"type": "string"},
                        },
                        "required": ["content", "filename"],
                        "additionalProperties": False,
                    },
                    "description": "Files to attach, each as base64 content with a file name.",
                }
            elif tool.name == "get_gmail_attachment_content" and self.inline_attachments:
                description = "Download a Gmail attachment. Set return_base64=true to get the ORIGINAL file, not a PDF conversion: structuredContent.result is a JSON string with filename, mime_type and content (standard base64). Inside codemode parse that JSON and pass these fields to file_import with encoding base64; then edit using Office or text tools. Never return the base64 to model context. With return_base64=false, preview only: "
                description += f"an image or the first {MAX_PDF_PAGES} pages of a PDF come back as images, a text file as text (up to {MAX_TEXT_CHARS} characters); "
                description += (
                    "HTML and any other document (Word, Excel, PowerPoint, OpenDocument, RTF, other image formats…) is converted to PDF with Gotenberg and comes back as its page images, marked as a conversion that may differ from the original."
                    if self.gotenberg_url
                    else "other files cannot be read."
                )
            elif tool.name == "get_gmail_attachment_content":
                description = "Download a Gmail attachment. Read it in the sandbox at /workspace/attachments/<Saved filename> using the Saved filename from the response, not the host-side Saved to path. Downloads expire after one hour; copy files elsewhere in /workspace to retain them."
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
        original = name == "get_gmail_attachment_content" and arguments.get("return_base64", False)
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
        elif name in {"draft_gmail_message", "send_gmail_message"}:
            attachments = arguments.get("attachments")
            if attachments:
                arguments["attachments"] = mail_attachments(attachments)
            if arguments.get("from_email") not in (None, "", self.email):
                raise ToolError("Mail must use the configured Google account.")
            arguments["include_signature"] = False
        elif name == "get_gmail_attachment_content" and self.inline_attachments:
            if not isinstance(original, bool):
                raise ToolError("return_base64 must be a boolean.")
            # Read the saved original ourselves; upstream's textual base64 block is unnecessary.
            arguments["return_base64"] = False

        context = context.copy(
            message=context.message.model_copy(update={"arguments": arguments})
        )
        result = await call_next(context)
        if name != "get_gmail_attachment_content" or not self.inline_attachments:
            return result
        text = "\n".join(block.text for block in result.content if isinstance(block, TextContent))
        saved_paths = re.findall(r"^📎 Saved to: (.+)$", text, re.MULTILINE)
        if not saved_paths:
            if original:
                raise ToolError("The original attachment could not be downloaded. Fetch the message again to obtain a current attachment ID.")
            return result
        # Filenames are untrusted mail metadata and may contain forged response lines.
        saved_path = Path(saved_paths[-1]).resolve()
        attachment_directory = Path(os.environ["WORKSPACE_ATTACHMENT_DIR"]).resolve()
        if saved_path.parent != attachment_directory:
            raise ToolError("The saved attachment is outside the configured attachment directory.")
        filename = re.search(r"^Filename: (.+)$", text, re.MULTILINE)
        try:
            if original:
                import base64

                name = filename.group(1) if filename else saved_path.name
                with open(saved_path, "rb") as source:
                    data = source.read(64 * 1024 * 1024 + 1)
                if len(data) > 64 * 1024 * 1024:
                    raise ToolError("The attachment exceeds the 64 MiB file limit.")
                payload = json.dumps({
                    "filename": name,
                    "mime_type": mimetypes.guess_type(name)[0] or "application/octet-stream",
                    "content": base64.b64encode(data).decode("ascii"),
                })
                return ToolResult(
                    content=[TextContent(type="text", text=payload)],
                    structured_content={"result": payload},
                )
            name = filename and filename.group(1)
            mime_type = mimetypes.guess_type(name or saved_path)[0] or mimetypes.guess_type(saved_path)[0] or ""
            content = await attachment_content(
                saved_path.read_bytes(), name, mime_type, self.gotenberg_url
            )
        except Exception:
            if original:
                raise
            logging.exception("Could not read the attachment")
            content = [TextContent(type="text", text="The attachment could not be read.")]
        finally:
            saved_path.unlink()
        summary = text.split("\n📎", 1)[0]
        # The tool declares its text as structured output.
        return ToolResult(
            content=[TextContent(type="text", text=summary), *content],
            structured_content={"result": summary},
        )


def main():
    with open(sys.argv[1], encoding="utf-8") as policy_file:
        policy = json.load(policy_file)
    email = os.environ["USER_GOOGLE_EMAIL"]

    logging.basicConfig(level=logging.WARNING)
    logging.getLogger().setLevel(logging.WARNING)
    import main as upstream

    upstream.server.add_middleware(
        WorkspacePolicy(
            policy["allowedTools"],
            email,
            policy.get("inlineAttachments", False),
            policy.get("gotenbergUrl"),
        )
    )
    sys.argv = [
        "workspace-mcp",
        "--transport", "stdio",
        "--permissions",
        "gmail:send" if "send_gmail_message" in policy["allowedTools"] else "gmail:drafts",
        "calendar:full",
    ]
    upstream.main()


if __name__ == "__main__":
    main()
