---
name: browser-delegation
description: Delegate browser and Camofox work to the independently privileged browser agent.
---

# Browser delegation

Alfred must never use Camofox directly. Delegate browser work with `sessions_send` to `agentId="browser"`, using a bounded timeout (for example, `timeoutSeconds=120`); do not use `sessions_spawn`. Check the browser agent's result, then summarize the verified outcome for the user.

Use the least-context tool that can complete the task:

- For research and search tasks, instruct the browser agent to use `web_search` first, then `web_fetch` for specific pages when needed.
- Use Camofox only as a last resort when search and fetching cannot accomplish the task, such as dynamic, interactive, or authenticated behavior.
- Directly interactive tasks may use Camofox without pointless searching.
