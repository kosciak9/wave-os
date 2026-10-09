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
# The image formats models read; other images are converted like documents.
MODEL_IMAGE_TYPES = {"image/jpeg", "image/png", "image/gif", "image/webp"}
# What Gotenberg renders with Chromium, which keeps the look; LibreOffice takes the rest.
CHROMIUM_TYPES = {"text/html", "application/xhtml+xml"}
CHROMIUM_IMAGE_TYPES = {
    "image/svg+xml",
    "image/bmp",
    "image/avif",
    "image/x-icon",
    "image/vnd.microsoft.icon",
}


def pdf_pages(data, label):
    import base64

    import pymupdf

    document = pymupdf.open(stream=data, filetype="pdf")
    pages = []
    for page in document.pages(0, min(document.page_count, MAX_PDF_PAGES)):
        zoom = PDF_PAGE_PIXELS / max(page.rect.width, page.rect.height)
        pixmap = page.get_pixmap(matrix=pymupdf.Matrix(zoom, zoom))
        jpeg = base64.b64encode(pixmap.tobytes("jpeg", jpg_quality=80)).decode("ascii")
        pages.append(ImageContent(type="image", data=jpeg, mimeType="image/jpeg"))
    shown = f"pages 1–{len(pages)} of {document.page_count}"
    return [TextContent(type="text", text=f"{label}, {shown}, as images:"), *pages]


async def convert_to_pdf(data, filename, mime_type, gotenberg_url):
    """The file rendered to PDF by Gotenberg, and the engine that rendered it.

    Chromium takes HTML and the images it decodes, LibreOffice everything else,
    picking the format by extension.
    """
    import html

    import httpx

    name = re.sub(r"[^\w.-]", "_", os.path.basename(filename or "")) or "attachment"
    if not os.path.splitext(name)[1]:
        name += mimetypes.guess_extension(mime_type) or ""
    if mime_type in CHROMIUM_TYPES:
        engine, route, files = "Chromium", "chromium/convert/html", [("files", ("index.html", data))]
    elif mime_type in CHROMIUM_IMAGE_TYPES:
        page = f'<img src="{html.escape(name)}" style="max-width:100%">'
        engine, route = "Chromium", "chromium/convert/html"
        files = [("files", ("index.html", page.encode())), ("files", (name, data))]
    else:
        engine, route, files = "LibreOffice", "libreoffice/convert", [("files", (name, data))]
    async with httpx.AsyncClient(timeout=120) as client:
        response = await client.post(f"{gotenberg_url}/forms/{route}", files=files)
    response.raise_for_status()
    return response.content, engine


async def attachment_content(path, filename, gotenberg_url=None):
    """The saved attachment as content a model reads: images, PDF pages as images, or text.

    Any other file is rendered to PDF first when Gotenberg is configured, and says so.
    """
    import base64

    mime_type = mimetypes.guess_type(filename or path)[0] or mimetypes.guess_type(path)[0] or ""
    with open(path, "rb") as source:
        data = source.read()
    if mime_type == "application/pdf":
        return pdf_pages(data, "PDF")
    if mime_type in MODEL_IMAGE_TYPES:
        if len(data) > MAX_IMAGE_BYTES:
            return [TextContent(type="text", text=f"The image ({mime_type}) is too large to show.")]
        return [ImageContent(type="image", data=base64.b64encode(data).decode("ascii"), mimeType=mime_type)]
    if (mime_type.startswith("text/") or mime_type in TEXT_TYPES) and not (
        gotenberg_url and mime_type in CHROMIUM_TYPES
    ):
        text = data.decode("utf-8", errors="replace")
        if len(text) > MAX_TEXT_CHARS:
            text = text[:MAX_TEXT_CHARS] + f"\n[… cut at {MAX_TEXT_CHARS} of {len(text)} characters]"
        return [TextContent(type="text", text=text)]
    kind = mime_type or "binary"
    if not gotenberg_url:
        return [TextContent(type="text", text=f"The content of a {kind} file cannot be shown.")]
    try:
        pdf, engine = await convert_to_pdf(data, filename, mime_type, gotenberg_url)
    except Exception:
        logging.exception("Could not convert the attachment to PDF")
        return [TextContent(type="text", text=f"The content of a {kind} file cannot be shown: converting it to PDF with Gotenberg failed.")]
    label = (
        f"Not the original file: this {kind} file was converted to PDF with Gotenberg ({engine}), "
        "so it may look different from the original and anything that could not be rendered is missing; the PDF"
    )
    return pdf_pages(pdf, label)


def draft_attachments(attachments):
    """Only base64 content: the upstream draft tool also reads host paths and fetches URLs."""
    import base64
    import binascii

    if isinstance(attachments, str):
        try:
            attachments = json.loads(attachments)
        except ValueError:
            raise ToolError("Draft attachments must be a list of files.") from None
    if not isinstance(attachments, list):
        raise ToolError("Draft attachments must be a list of files.")
    for attachment in attachments:
        if not isinstance(attachment, dict) or not attachment.keys() <= {"content", "filename", "mime_type"}:
            raise ToolError("Draft attachments may only carry base64 content, a file name and a MIME type; host files and URLs are not permitted.")
        content, filename = attachment.get("content"), attachment.get("filename")
        mime_type = attachment.get("mime_type")
        if not isinstance(content, str) or not content or not isinstance(filename, str) or not filename:
            raise ToolError("Every draft attachment needs base64 content and a file name.")
        if mime_type is not None and not isinstance(mime_type, str):
            raise ToolError("A draft attachment's MIME type must be a string.")
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
            elif tool.name == "draft_gmail_message":
                description = "Create a text or HTML Gmail draft, optionally as a reply, with attachments passed as base64 content. Does not send mail or read host files, attachment URLs or account signatures."
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
                description = f"Read a Gmail attachment: an image or the first {MAX_PDF_PAGES} pages of a PDF come back as images, a text file as text (up to {MAX_TEXT_CHARS} characters); "
                description += (
                    "HTML and any other document (Word, Excel, PowerPoint, OpenDocument, RTF, other image formats…) is converted to PDF with Gotenberg and comes back as its page images, marked as a conversion that may differ from the original."
                    if self.gotenberg_url
                    else "other files cannot be read."
                )
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
            attachments = arguments.get("attachments")
            if attachments:
                arguments["attachments"] = draft_attachments(attachments)
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
            content = await attachment_content(
                saved.group(1), filename and filename.group(1), self.gotenberg_url
            )
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
        "--permissions", "gmail:drafts", "calendar:full",
    ]
    upstream.main()


if __name__ == "__main__":
    main()
