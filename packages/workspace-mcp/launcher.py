import json
import logging
import mimetypes
import os
import re
import sys

from fastmcp.exceptions import ToolError
from fastmcp.server.middleware import Middleware
from fastmcp.tools.tool import ToolResult
from mcp.types import ImageContent, TextContent

MAX_PDF_PAGES = 10
PDF_PAGE_PIXELS = 1600
MAX_TEXT_CHARS = 100_000
MAX_IMAGE_BYTES = 10 * 1024 * 1024
TEXT_TYPES = {"application/json", "application/xml", "application/x-yaml", "application/csv"}


def attachment_content(path, filename):
    """The saved attachment as content a model reads: images, PDF pages as images, or text."""
    import base64

    mime_type = mimetypes.guess_type(filename or path)[0] or mimetypes.guess_type(path)[0] or ""
    with open(path, "rb") as source:
        data = source.read()
    if mime_type == "application/pdf":
        import pymupdf

        document = pymupdf.open(stream=data, filetype="pdf")
        pages = []
        for page in document.pages(0, min(document.page_count, MAX_PDF_PAGES)):
            zoom = PDF_PAGE_PIXELS / max(page.rect.width, page.rect.height)
            pixmap = page.get_pixmap(matrix=pymupdf.Matrix(zoom, zoom))
            jpeg = base64.b64encode(pixmap.tobytes("jpeg", jpg_quality=80)).decode("ascii")
            pages.append(ImageContent(type="image", data=jpeg, mimeType="image/jpeg"))
        shown = f"pages 1–{len(pages)} of {document.page_count}"
        return [TextContent(type="text", text=f"PDF, {shown}, as images:"), *pages]
    if mime_type.startswith("image/"):
        if len(data) > MAX_IMAGE_BYTES:
            return [TextContent(type="text", text=f"The image ({mime_type}) is too large to show.")]
        return [ImageContent(type="image", data=base64.b64encode(data).decode("ascii"), mimeType=mime_type)]
    if mime_type.startswith("text/") or mime_type in TEXT_TYPES:
        text = data.decode("utf-8", errors="replace")
        if len(text) > MAX_TEXT_CHARS:
            text = text[:MAX_TEXT_CHARS] + f"\n[… cut at {MAX_TEXT_CHARS} of {len(text)} characters]"
        return [TextContent(type="text", text=text)]
    return [TextContent(type="text", text=f"The content of a {mime_type or 'binary'} file cannot be shown.")]


class WorkspacePolicy(Middleware):
    def __init__(self, allowed_tools, email, inline_attachments=False):
        self.allowed_tools = frozenset(allowed_tools)
        self.email = email
        # Attachments come back as their content, for clients that cannot read the host's files.
        self.inline_attachments = inline_attachments

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
            elif tool.name == "get_gmail_attachment_content" and self.inline_attachments:
                description = f"Read a Gmail attachment: an image or the first {MAX_PDF_PAGES} pages of a PDF come back as images, a text file as text (up to {MAX_TEXT_CHARS} characters); other files cannot be read."
                properties.pop("return_base64", None)
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
        elif name == "get_gmail_attachment_content" and self.inline_attachments:
            arguments.pop("return_base64", None)

        context = context.copy(
            message=context.message.model_copy(update={"arguments": arguments})
        )
        result = await call_next(context)
        if name != "get_gmail_attachment_content" or not self.inline_attachments:
            return result
        text = "\n".join(block.text for block in result.content if isinstance(block, TextContent))
        saved = re.search(r"^📎 Saved to: (.+)$", text, re.MULTILINE)
        if not saved:
            return result
        filename = re.search(r"^Filename: (.+)$", text, re.MULTILINE)
        try:
            content = attachment_content(saved.group(1), filename and filename.group(1))
        except Exception:
            logging.exception("Could not read the attachment")
            content = [TextContent(type="text", text="The attachment could not be read.")]
        finally:
            os.unlink(saved.group(1))
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
        WorkspacePolicy(policy["allowedTools"], email, policy.get("inlineAttachments", False))
    )
    sys.argv = [
        "workspace-mcp",
        "--transport", "stdio",
        "--permissions", "gmail:drafts", "calendar:full",
    ]
    upstream.main()


if __name__ == "__main__":
    main()
