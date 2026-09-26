/**
 * Local OpenCode v2 provider for ChatGPT/Codex web search.
 *
 * The Responses request and SSE handling follow the MIT-licensed
 * opencode-websearch v0.6.0 ChatGPT adapter:
 * https://github.com/emilsvennesson/opencode-websearch/tree/v0.6.0
 * This adapter deliberately resolves only OpenCode's OAuth connection; it
 * never falls back to an API key or another paid search service.
 */
const CODEX_RESPONSES_URL = "https://chatgpt.com/backend-api/codex/responses"
const USER_AGENT = "opencode-codex-websearch"
const SOURCE_INCLUDE = ["web_search_call.action.sources"]
const SEARCH_INSTRUCTIONS =
  "You are a web search assistant. Search the web and return the most relevant sources for the user's query."

type RecordLike = Record<string, unknown>

type SearchResult = {
  url: string
  title: string
  content?: string
  time: Record<string, never>
}

type PluginContext = {
  integration: {
    connection: {
      active(provider: string): Promise<unknown>
      resolve(connection: unknown): Promise<unknown>
    }
  }
}

type SearchSource = {
  url: string
  title: string
  content?: string
}

const isRecord = (value: unknown): value is RecordLike =>
  typeof value === "object" && value !== null

const nonEmptyString = (value: unknown): string | undefined =>
  typeof value === "string" && value.length > 0 ? value : undefined

const credentialValue = (value: unknown): RecordLike | undefined => {
  if (!isRecord(value)) return undefined
  // Keep this tolerant of additions to CredentialValue, but require the
  // discriminator so an API key or arbitrary object cannot be mistaken for
  // ChatGPT OAuth.
  return value.type === "oauth" ? value : undefined
}

const resolveOAuth = async (ctx: PluginContext): Promise<{ access: string; accountId: string }> => {
  const connection = await ctx.integration.connection.active("openai")
  if (!connection) {
    throw new Error(
      "Codex web search requires an active OpenAI ChatGPT OAuth connection; connect OpenAI with /connect.",
    )
  }

  const credential = credentialValue(
    await ctx.integration.connection.resolve(connection),
  )
  const access = credential && nonEmptyString(credential.access)
  const methodID = credential && nonEmptyString(credential.methodID)
  const metadata = credential && isRecord(credential.metadata) ? credential.metadata : undefined
  const accountId = metadata && nonEmptyString(metadata.accountID)
  if (
    !access ||
    !accountId ||
    (methodID !== "chatgpt-browser" && methodID !== "chatgpt-headless")
  ) {
    throw new Error(
      "Codex web search requires OpenAI ChatGPT OAuth credentials with access, metadata.accountID, and a supported ChatGPT browser method; no paid API fallback is available.",
    )
  }
  return { access, accountId }
}

const sourceURL = (value: unknown): string | undefined => {
  if (!isRecord(value)) return undefined
  const url = nonEmptyString(value.url)
  if (!url) return undefined
  try {
    const parsed = new URL(url)
    return parsed.protocol === "http:" || parsed.protocol === "https:" ? url : undefined
  } catch {
    return undefined
  }
}

const parseSSE = async (response: Response): Promise<{ text: string; sources: SearchSource[] }> => {
  if (!response.body) throw new Error("Codex web search returned an empty response body")
  const decoder = new TextDecoder()
  const sources: SearchSource[] = []
  const seen = new Set<string>()
  let text = ""
  let buffer = ""
  let eventBuffer = ""

  const consume = (block: string) => {
    let event = ""
    const data: string[] = []
    for (const line of block.split(/\r?\n/)) {
      if (line.startsWith("event:")) event = line.slice(6).trimStart()
      if (line.startsWith("data:")) data.push(line.slice(5).trimStart())
    }
    if (!event || data.length === 0) return
    let parsed: RecordLike
    try {
      parsed = JSON.parse(data.join("\n")) as RecordLike
    } catch {
      return
    }
    if (event === "response.output_text.delta") {
      const delta = nonEmptyString(parsed.delta)
      if (delta) text += delta
      return
    }
    if (event !== "response.output_item.done" || !isRecord(parsed.item)) return
    if (parsed.item.type !== "web_search_call" || !isRecord(parsed.item.action)) return
    const action = parsed.item.action
    if (action.type !== "search" || !Array.isArray(action.sources)) return
    for (const source of action.sources) {
      const url = sourceURL(source)
      if (url && !seen.has(url)) {
        seen.add(url)
        const record = isRecord(source) ? source : {}
        sources.push({
          url,
          title: nonEmptyString(record.title) ?? url,
          content: nonEmptyString(record.content) ?? nonEmptyString(record.snippet),
        })
      }
    }
  }

  const consumeLine = (line: string) => {
    if (line.trim() === "") {
      consume(eventBuffer)
      eventBuffer = ""
      return
    }
    eventBuffer += `${line}\n`
  }

  for await (const chunk of response.body) {
    const incoming = decoder.decode(chunk, { stream: true })
    buffer += incoming
    let newline: number
    while ((newline = buffer.search(/[\r\n]/)) !== -1) {
      // A CRLF terminator can be split across response chunks. Keep a
      // trailing CR buffered until the following chunk tells us whether it
      // is followed by LF; otherwise the LF would look like an extra blank
      // line and prematurely dispatch the SSE event.
      if (buffer[newline] === "\r" && newline + 1 === buffer.length) break
      const line = buffer.slice(0, newline)
      const terminator = buffer[newline] === "\r" && buffer[newline + 1] === "\n" ? 2 : 1
      buffer = buffer.slice(newline + terminator)
      consumeLine(line)
    }
  }
  buffer += decoder.decode()
  if (buffer.trim()) consumeLine(buffer)
  if (eventBuffer.trim()) consume(eventBuffer)
  return { text: text.trim(), sources }
}

const execute = async (
  query: string,
  ctx: PluginContext,
  signal?: AbortSignal,
): Promise<readonly SearchResult[]> => {
  const { access, accountId } = await resolveOAuth(ctx)
  const response = await fetch(CODEX_RESPONSES_URL, {
    method: "POST",
    signal,
    headers: {
      Accept: "text/event-stream",
      Authorization: `Bearer ${access}`,
      "Content-Type": "application/json",
      "User-Agent": USER_AGENT,
      "chatgpt-account-id": accountId,
    },
    body: JSON.stringify({
      include: SOURCE_INCLUDE,
      instructions: SEARCH_INSTRUCTIONS,
      input: [
        {
          role: "user",
          content: [{ type: "input_text", text: `Perform a web search for the query: ${query}` }],
        },
      ],
      model: "gpt-5-codex",
      store: false,
      stream: true,
      tool_choice: "auto",
      tools: [{ type: "web_search" }],
    }),
  })
  if (!response.ok) {
    throw new Error(`Codex web search failed with HTTP status ${response.status}`)
  }

  const parsed = await parseSSE(response)
  if (parsed.sources.length > 0) {
    return parsed.sources.map((source) => ({ ...source, content: source.content ?? parsed.text, time: {} }))
  }
  throw new Error(
    parsed.text
      ? "Codex web search returned text without source URLs"
      : "Codex web search returned no source URLs",
  )
}

export default {
  id: "codex-websearch",
  async setup(ctx) {
    await ctx.websearch.transform((editor) => {
      editor.add({
        id: "codex",
        name: "ChatGPT Codex web search",
        execute: ({ query }, options) => execute(query, ctx, options?.signal),
      })
      editor.default.set("codex")
    })
  },
}
