import sanitizeHtml from "sanitize-html";
import TurndownService from "turndown";
import { z } from "zod";

const indexSchema = z.number().int().nonnegative();
const messageSchema = z.object({
  html_body: z.array(indexSchema),
  text_body: z.array(indexSchema),
  attachments: z.array(indexSchema),
  parts: z.array(z.object({ body: z.unknown() })),
});
const htmlPartSchema = z.object({ Html: z.string() }).strict();
const textPartSchema = z.object({ Text: z.string() }).strict();
const bodyPartSchema = z.union([htmlPartSchema, textPartSchema]);
const layoutTags = new Set([
  "div",
  "span",
  "p",
  "table",
  "thead",
  "tbody",
  "tfoot",
  "tr",
  "th",
  "td",
]);

const markdown = new TurndownService({
  headingStyle: "atx",
  bulletListMarker: "-",
  codeBlockStyle: "indented",
});
const escapeMarkdown = markdown.escape.bind(markdown);
// Entity-decoded text must not become active HTML when Markdown is rendered.
markdown.escape = (text) => escapeMarkup(escapeMarkdown(text));
markdown.addRule("tableLayout", {
  filter: ["table", "thead", "tbody", "tfoot", "tr", "th", "td", "caption"],
  replacement: (content) => `\n\n${content}\n\n`,
});
for (const [index, tag] of (
  ["h1", "h2", "h3", "h4", "h5", "h6"] as const
).entries()) {
  const level = Math.min(6, index + 3);
  markdown.addRule(`compact-${tag}`, {
    filter: tag,
    replacement: (content) => `\n\n${"#".repeat(level)} ${content}\n\n`,
  });
}

function safeHref(href: string | undefined): string | null {
  if (!href || /[\u0000-\u0020\u007f-\u009f]/.test(href)) return null;
  try {
    const url = new URL(href);
    if (url.protocol === "http:" || url.protocol === "https:") {
      return /^https?:\/\//i.test(href) && url.hostname ? url.href : null;
    }
    return url.protocol === "mailto:" && url.pathname ? url.href : null;
  } catch {
    return null;
  }
}

export function htmlMarkdown(html: string): string {
  const clean = sanitizeHtml(html, {
    allowedTags: [
      "h1",
      "h2",
      "h3",
      "h4",
      "h5",
      "h6",
      "p",
      "div",
      "span",
      "blockquote",
      "br",
      "hr",
      "ul",
      "ol",
      "li",
      "strong",
      "b",
      "em",
      "i",
      "pre",
      "code",
      "a",
      "table",
      "thead",
      "tbody",
      "tfoot",
      "tr",
      "th",
      "td",
      "caption",
    ],
    allowedAttributes: { "*": ["hidden", "style"], a: ["href"] },
    // Only hiding declarations survive CSS parsing; hidden subtrees are then discarded.
    allowedStyles: {
      "*": { display: [/^none$/i], visibility: [/^hidden$/i] },
    },
    exclusiveFilter: (frame) =>
      "hidden" in frame.attribs ||
      "style" in frame.attribs ||
      (layoutTags.has(frame.tag) &&
        !frame.text.replace(
          /[\s\u00ad\u034f\u200b-\u200f\u2060-\u206f\ufeff]/g,
          "",
        )),
    allowedSchemes: ["http", "https", "mailto"],
    allowProtocolRelative: false,
    nonTextTags: [
      "script",
      "style",
      "textarea",
      "option",
      "xmp",
      "noscript",
      "svg",
      "math",
      "iframe",
      "object",
      "embed",
      "form",
      "video",
      "audio",
      "picture",
    ],
    transformTags: {
      a: (_tag, attributes): sanitizeHtml.Tag => {
        const href = safeHref(attributes.href);
        const attribs = { ...attributes };
        if (href) attribs.href = href;
        else delete attribs.href;
        return { tagName: "a", attribs };
      },
    },
  });
  return markdown.turndown(clean);
}

export function textMarkdown(text: string): string {
  return text
    .split(/\r?\n/)
    .map((line) => markdown.escape(line))
    .join("\n");
}

export function escapeMarkup(text: string): string {
  return text
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

export function messageMarkdown(value: unknown): string {
  const parsed = messageSchema.safeParse(value);
  if (!parsed.success) throw new Error("Unsupported Himalaya message JSON");
  const message = parsed.data;
  const attachments = new Set(message.attachments);
  const bodies = new Map<number, z.infer<typeof bodyPartSchema>>();
  for (const index of [
    ...message.html_body,
    ...message.text_body,
    ...message.attachments,
  ]) {
    if (index >= message.parts.length)
      throw new Error("Invalid MIME body index");
  }
  for (const index of new Set([...message.html_body, ...message.text_body])) {
    if (attachments.has(index)) continue;
    const part = bodyPartSchema.safeParse(message.parts[index]?.body);
    if (!part.success) throw new Error("Invalid MIME body type");
    bodies.set(index, part.data);
  }
  function render(indexes: number[]): string {
    return [...new Set(indexes)]
      .flatMap((index) => {
        const part = bodies.get(index);
        if (!part) return [];
        return [
          "Html" in part ? htmlMarkdown(part.Html) : textMarkdown(part.Text),
        ];
      })
      .join("\n\n")
      .replace(/^\n+|\n+$/g, "");
  }
  const hasHtml = message.html_body.some((index) => {
    const part = bodies.get(index);
    return part !== undefined && "Html" in part;
  });
  const preferred = render(hasHtml ? message.html_body : message.text_body);
  if (preferred.trim()) return preferred;
  const fallback = render(hasHtml ? message.text_body : message.html_body);
  return fallback.trim() ? fallback : "No readable message body.";
}
