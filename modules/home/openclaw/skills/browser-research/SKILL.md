---
name: browser-research
description: Choose efficient browser tools for evidence-based research and interaction.
---

# Browser research

Choose tools based on the task rather than following a fixed workflow:

- `web_search` is broad and low-overhead for current information, discovery, candidate sources, and snippets.
- `web_fetch` efficiently extracts detail from known URLs, but may not handle dynamic pages, authentication, or resistant content.
- Camofox provides stateful interaction for dynamic or authenticated pages, forms, and other browser actions, at higher latency and context/state cost.

Search and fetch can be combined when useful, and a direct interactive task can use Camofox without preliminary search. Available Camofox operations are `camofox_create_tab`, `camofox_navigate`, `camofox_snapshot`, `camofox_click`, `camofox_type`, `camofox_select`, `camofox_scroll`, `camofox_list_tabs`, and `camofox_close_tab`. Snapshots are text-only; follow `nextOffset` when paginated. Use current snapshot references for interaction; use `camofox_select` for native select options rather than typing or evaluating scripts. Close tabs when finished.

If `browser_execute` is available, use it only for one bounded current subgoal in an existing tab. Give variables descriptive names, specify a grounded completion check (visible text or URL path), and inspect the outcome. On refusal, uncertainty, or escalation, inspect a fresh snapshot and take over with low-level tools or ask the user; do not repeat the same refused invocation. Prefer search/fetch for straightforward research.

For `tool_call`, use the accepted unqualified `camofox_*` or `browser_execute` IDs, never an `openclaw:` prefix; if lookup shows a qualified ID, use its accepted short ID.

Verify claims against sources, distinguish retrieved facts from inference, and return concise findings with relevant sources and material limitations.
