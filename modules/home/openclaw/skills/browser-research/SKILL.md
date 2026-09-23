---
name: browser-research
description: Choose efficient browser tools for evidence-based research and interaction.
---

# Browser research

Choose tools based on the task rather than following a fixed workflow:

- `web_search` is broad and low-overhead for current information, discovery, candidate sources, and snippets.
- `web_fetch` efficiently extracts detail from known URLs, but may not handle dynamic pages, authentication, or resistant content.
- Camofox provides stateful interaction for dynamic or authenticated pages, forms, and other browser actions, at higher latency and context/state cost.

Search and fetch can be combined when useful, and a direct interactive task can use Camofox without preliminary search. Available Camofox operations are `camofox_create_tab`, `camofox_navigate`, `camofox_snapshot`, `camofox_click`, `camofox_type`, `camofox_scroll`, `camofox_list_tabs`, and `camofox_close_tab`. Use snapshot references for interaction and close tabs when finished.

Verify claims against sources, distinguish retrieved facts from inference, and return concise findings with relevant sources and material limitations.
