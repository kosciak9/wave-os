---
name: browser-delegation
description:
  Delegate browser research and interaction to the independently privileged
  browser agent.
---

# Browser delegation

Alfred must never use Camofox directly. For browser work, spawn a fresh child
with `sessions_spawn`, passing `agentId="browser"`, `model="xai/grok-4.7"`,
`thinking="off"`, `context="isolated"`, `visible=false`, `sandbox="require"`,
`runTimeoutSeconds=900`, and `cleanup="delete"`. Use Grok 4.7 with thinking off
for extraction and well-scoped routine research. For complex, multi-source, or
contradictory research, use `model="openai/gpt-6.1-sol"` with
`thinking="medium"`; if Grok 4.7's result is insufficient, one bounded retry
with that Sol configuration is also allowed. This is a per-task model choice,
not a browser default-model fallback. Give it one bounded, explicit task. Do not
use `sessions_send` or reuse a persistent browser peer. Each task gets a fresh
child; the child returns its result via announce, and Alfred summarizes the
verified outcome for the user. Use `sessions_yield` to await completion rather
than polling, and do not send the result twice. The spawn's `cleanup="delete"`
archives the child after it announces.

Delegate both simple web research and interactive browser use to Browser via a
fresh child. The child chooses the appropriate tools, using `web_search` or
`web_fetch` without Camofox when possible. Independent browser tasks may run as
parallel children.

## Login profiles

Browser profiles keep a logged-in account across tasks. You decide which profile
a task uses and name it in the task, e.g. "use browser profile `linkedin`";
otherwise the child works in an anonymous throwaway session. Profile names are
lowercase letters, digits and hyphens. Keep a memory note per profile: the
account and sites it holds, when the owner last logged in, and whether it still
worked. Search memory before choosing a profile; never put credentials in memory
or tasks.

When a child reports that login is required, or the owner asks to log in:

1. Call `browser_login_open({profile, url})` with the login page.
2. Send the owner the returned `viewerUrl` (reachable over Tailscale) and ask
   them to log in there and reply when done.
3. After they confirm, call `browser_login_save({profile})`, update the
   profile's memory note, and only then re-delegate the original task.

Never ask the owner for passwords, codes or cookies in chat.

The browser agent chooses and composes tools according to the task:

- `web_search` is broad and low-overhead: use it to discover current
  information, locate candidate sources, and gather snippets. Results can be
  incomplete or lack page detail.
- `web_fetch` is efficient for extracting detail from known URLs, but is limited
  by dynamic pages, authentication, and pages that resist extraction.
- `lightpanda_read` renders public JavaScript pages as markdown cheaply, but it
  cannot log in or interact and is easily blocked as a bot.
- Camofox is stateful and suited to dynamic or interactive pages,
  authentication, forms, and other browser actions; it has higher latency and
  context/state overhead.

These are task-dependent options, not a mandatory sequence. Search and fetch may
be combined when useful, while a direct interactive task may go straight to
Camofox. Report the approach used and any source, access, or material
limitations.
