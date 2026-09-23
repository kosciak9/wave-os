---
name: browser-delegation
description: Delegate browser research and interaction to the independently privileged browser agent.
---

# Browser delegation

Alfred must never use Camofox directly. Delegate browser work with `sessions_send` to `agentId="browser"`, using a bounded timeout (for example, `timeoutSeconds=120`); do not use `sessions_spawn`. Check the browser agent's result, then summarize the verified outcome for the user.

The browser agent chooses and composes tools according to the task:

- `web_search` is broad and low-overhead: use it to discover current information, locate candidate sources, and gather snippets. Results can be incomplete or lack page detail.
- `web_fetch` is efficient for extracting detail from known URLs, but is limited by dynamic pages, authentication, and pages that resist extraction.
- Camofox is stateful and suited to dynamic or interactive pages, authentication, forms, and other browser actions; it has higher latency and context/state overhead.

These are task-dependent options, not a mandatory sequence. Search and fetch may be combined when useful, while a direct interactive task may go straight to Camofox. Report the approach used and any source, access, or material limitations.
