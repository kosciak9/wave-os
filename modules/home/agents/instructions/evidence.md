# Evidence and source links

Distinguish documented behavior, observed implementation, and community opinion.
Mark factual claims that cannot yet be verified as `[CONTEXT MISSING]` and state
what was checked. Keep working assumptions distinct from missing evidence.

- Link source-code findings with Markdown links labeled by readable
  repo-relative `path:line` (or `path:start-end`) and targeting the exact
  inspected checkout with an absolute Markdown file link and optional line
  number (`/absolute/path:42`). Keep the visible path readable as a fallback
  when links cannot be opened.

  > Example: `[modules/example.nix:42](/workspace/repo/modules/example.nix:42)`.

- Use local absolute file links only for private or session-specific findings.
  In public PRs and issues, use shareable repository web links or relative
  `path:line` references; never expose local host paths.
- Link external sources with descriptive labels and their actual URLs. For code,
  use the inspected revision and line anchor when available.
