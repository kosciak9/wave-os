---
name: technical-investigation
description: >-
  Gather and evaluate factual evidence from code and documentation. Use when
  investigating behavior, resolving factual uncertainties, or supporting a
  planning or implementation decision with checkable findings.
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
  inspected checkout with an absolute `file:` URI and `#L<number>` anchor.
  Percent-encode spaces and other URL characters in the URI; keep the visible
  path readable as a fallback when links cannot be opened.

  > Example:
  > [`modules/example.nix:42`](file:///workspace/repo/modules/example.nix#L42)

- Link external sources with descriptive Markdown labels and their real URLs.
  For source code in another repository, use its exact revision and line anchor
  when available. Never invent paths, line numbers, or URLs.
- Use local absolute file links only for private or session-specific findings.
  In public PRs and issues, use shareable repository web links or relative
  `path:line` references; never expose local host paths. Do not use
  editor-specific link schemes or assume a particular link handler.

## Factual uncertainties and open decisions

- Resolve factual uncertainties through code inspection or primary sources
  during research blocks where possible.

  > Example: inspect the repository to find which module installs skills instead
  > of asking the user to identify it.

- Continue researching independent questions while a decision is open.

  > Example: compare supported skill formats while installation scope is
  > unresolved; do not finalize scope-dependent implementation steps as if that
  > decision had already been made.
