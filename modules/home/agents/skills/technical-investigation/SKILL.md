---
name: technical-investigation
description:
  "Evidence-gathering procedure for answering 'why/how/does it' questions from
  code, logs and docs. Use before answering any question about how something
  works, why it breaks, or whether something is possible."
when_to_use:
  "'zrób research czy da się X', 'dlaczego X nie działa', 'sprawdź jak działa
  Y', 'zbadaj', debugging a symptom, feasibility checks."
---

# Technical Investigation

## Evidence

Read code before making claims about it. Inspect the relevant implementation,
callers, and configuration rather than speculating about unseen code. Prefer
primary sources, record relevant versions, and include paths or URLs so findings
can be checked later. Include `path/to/file:line` references when discussing
code.

Distinguish documented behavior, observed implementation, and community opinion.
Never claim more certainty than the evidence supports. State what was searched
when evidence is missing. Mark unresolved claims as **[CONTEXT MISSING]**.

Use `[CONTEXT MISSING]` for claims that cannot yet be verified, not for
provisional choices made to proceed with the work.

## Link findings to their sources

- Link source-code findings with Markdown links labeled by readable
  repo-relative `path:line` (or `path:start-end`) and targeting the exact
  inspected checkout with `herdr-edit:///absolute/path?line=<number>`
  (optionally `&column=<number>`). Percent-encode spaces and other URL
  characters in the path; keep the visible path readable as a fallback when
  links cannot be opened.

  > Example:
  > `[modules/example.nix:42](herdr-edit:///workspace/repo/modules/example.nix?line=42)`.

- Link external sources with descriptive Markdown labels and their real URLs.
  For source code in another repository, use its exact revision and line anchor
  when available. Never invent paths, line numbers, or URLs.
- Use local absolute file links only for private or session-specific findings.
  In public PRs and issues, use shareable repository web links or relative
  `path:line` references; never expose local host paths.

## Factual uncertainties and open decisions

- Resolve factual uncertainties through code inspection or primary sources
  during research blocks where possible.

  > Example: inspect the repository to find which module installs skills instead
  > of asking the user to identify it.

- Continue researching independent questions while a decision is open.

  > Example: compare supported skill formats while installation scope is
  > unresolved; do not finalize scope-dependent implementation steps as if that
  > decision had already been made.
