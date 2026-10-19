"""Turns mail attachments into content a model reads; shared by Alfred's mail MCP servers."""

import logging
import mimetypes
import os
import re

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


async def attachment_content(data, filename, mime_type, gotenberg_url=None):
    """An attachment as content a model reads: images, PDF pages as images, or text.

    Any other file is rendered to PDF first when Gotenberg is configured, and says so.
    """
    import base64

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
