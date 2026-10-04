---
name: browser-research
description:
  Research with native web tools and safely delegate interactive steps to the
  browser executor.
---

# Browser research

Use `web_search` to discover sources and `web_fetch` for known static pages.
When `web_fetch` returns an empty or script-only page, read it with
`lightpanda_read`; it renders JavaScript but cannot log in or interact and is
easily blocked. Use Camofox for logged-in, bot-protected or interactive pages;
no preliminary search is required for a direct interactive task.

If the task names a browser profile, pass it as `profile` to your first
`camofox_create_tab`; all later tabs in this session use it and it cannot be
changed. Without a named profile, omit it. Never choose a profile on your own
and never type credentials. If a page requires a login, stop and report
`login_required` with the profile and the login URL so Alfred can ask the owner.

For interaction, create a tab and use `camofox_snapshot` to inspect its current
accessibility text (follow `nextOffset` where present). Start a coherent goal
with `browser_execute({goal, tabId, facts, constraints?, bindings?})`. Put known
values in `facts`; use `constraints.forbidActions` and
`constraints.allowedOrigins` for enforceable limits, rather than relying on goal
prose. Bind an ambiguous field only to an exact observed `{label, context}`. The
executor performs clicks, typing, selection, navigation and scrolling
internally; do not seek another direct mutation route.

Treat `needs_reasoning` as a semantic problem, not permission to guess. Examine
its observed evidence and available options. Call **`browser_resolve`** with
exactly `{continuation_id, resolution}`; never put `goal`, `tabId`, `facts`,
`constraints`, or `bindings` into this call, and never send `continuation_id` to
`browser_execute`. A grounded option resolution is
`{continuation_id, resolution:{type:"fact",key:problem.fact_key,value:chosenOption.value}}`;
use an exact observed `options[].value` or `options[].label`, never shorten or
paraphrase. A control choice is
`{continuation_id, resolution:{type:"choice",candidateId:problem.candidates[].id}}`.
Use `{continuation_id, resolution:{type:"finish"}}` only after verifying the
full goal, or `{continuation_id, resolution:{type:"user_input",question:"..."}}`
if the needed preference is unknown. `problem.fact_key` is the canonical field
key; if it is missing, do not invent one—obtain fresh evidence or ask the user.
If an invalid option is rejected and the continuation remains valid, correct the
canonical key/value and retry with that same token. Never retry an unchanged
refusal or resume after an unknown mutation. A quarantined or uncertain tab is
read-only: inspect and report the uncertainty and incident ID to the user; do
not retry a possibly dispatched mutation. Only the authorized human owner can
send the native `/browser_recover <incidentId> inspect` followed by
`/browser_recover <incidentId> ack` after reviewing the effects. Never
synthesize that command through model tools; a settlement error keeps quarantine
in place.

Use normal Browser reasoning to decide unresolved choices; the local model only
chooses among bounded mechanical candidates. Checkpoints and observed
submissions are not proof of business completion. Verify the result against
fresh evidence before making claims, distinguish facts from inference, cite
relevant sources, and close tabs when finished.
