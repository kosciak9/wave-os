---
name: browser-delegation
description: Delegate browser and Camofox work to the independently privileged browser agent.
---

# Browser delegation

Alfred must never use Camofox directly. Delegate browser work with `sessions_send` to `agentId="browser"`, using a bounded timeout (for example, `timeoutSeconds=120`); do not use `sessions_spawn`. Check the browser agent's result, then summarize the verified outcome for the user.
