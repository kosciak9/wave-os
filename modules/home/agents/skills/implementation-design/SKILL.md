---
name: implementation-design
description: >-
  Apply general implementation design principles when adding or changing code,
  configuration, or infrastructure: reuse of the platform, libraries, and
  existing mechanisms, scope, cognitive load, state ownership, naming, and
  comments. Use for implementation choices independent of language.
---

# Implementation Design

Design for the next person who must understand and change the implementation.
These principles also help assess existing code; they are not a separate review
process or permission to expand the task. Repository instructions and concrete
contracts take precedence over generic preferences.

## Before writing code

New code is maintenance surface. Before implementing a mechanism, check in this
order whether it already exists:

1. The language, runtime, or platform (standard library, web or OS APIs, Nix and
   NixOS options, framework built-ins).
2. Dependencies the project already installs.
3. Mechanisms the repository or its infrastructure already provides: secret
   management, job systems, configuration modules, native loading or discovery,
   existing helpers and patterns.

Verify availability in the documentation for the installed version, not from
memory. Then write only the glue that the existing mechanism does not cover. If
the existing mechanism cannot do the job, say what is missing before building a
replacement.

> Wire secrets through the secret manager the system already uses instead of a
> custom provisioning tool. Use a harness's native skill or plugin loading
> instead of writing a parallel loader.

## Grow what exists

Compose new behavior from the code, patterns, and dependencies already present.
Push the current structure and libraries until working within them becomes
genuinely painful, and a little beyond; only then extract a new abstraction,
dependency, or service. The patterns you introduce will be copied, so prefer the
project's existing conventions, vocabulary, and shapes over new ones.

When something new is justified, prefer the least invasive step: a change in the
codebase, then the schema, then a library, then infrastructure the project owns,
and an external service last. One database can carry queues, background jobs,
and much more before new infrastructure is warranted.

> In a framework with built-in changes, notifiers, and job integration, add the
> behavior through those mechanisms. Do not add a separate worker, lock, and
> polling loop beside them.

## Scope

Make the requested behavior correct with the smallest maintainable change. Do
not add options, fallbacks, retries, locks, workers, validation of impossible
states, or extension points without a demonstrated need. Fix adjacent defects
only when necessary for the requested behavior; surface independent cleanup
separately rather than quietly widening scope.

> Removing a redundant synchronization step needed by the feature is in scope.
> Renaming neighboring modules and replacing their state library is not an
> incidental part of adding one control.

## Reduce the amount a reader must remember

Make inputs, outputs, failure cases, and side effects visible. Prefer
straightforward control flow over clever compression. Name meaningful decisions
and values instead of leaving magic literals, flatten nesting where the language
supports it, and reject invalid shapes at their boundary so absence and
multiplicity do not spread: fetch a single record rather than a list of one. Do
not turn every expression into a helper: indirection also costs attention. A
small public interface should hide meaningful complexity, not merely relocate
it.

> Prefer a named eligibility decision to a long boolean expression embedded in a
> template. Avoid a chain of tiny wrappers that makes the reader open five files
> to discover what that decision means.

Abstractions should hide a stable responsibility or invariant. A little local
duplication is preferable to coupling unrelated behaviors through a configurable
universal helper.

## One source of truth

Identify authoritative state before adding a second representation. Derive
values that can be computed reliably from existing inputs; store a derived value
only for a demonstrated performance need, with an explicit consistency model.
Separate persistent facts, user intent, temporary drafts, cached results, and
presentation projections.

> Store the selected record's identity and derive its current display value. A
> draft intentionally allowed to diverge from the saved record is different.

## Names and comments

Use the project's vocabulary and naming conventions consistently. Names should
reveal purpose, value shape, and relevant effects. A longer, precise name is
better than a comment explaining what the code does.

Comments are scarce so that they stand out. Write one only for a non-obvious
invariant or constraint, or a deliberate departure from these principles,
stating why. Do not narrate the code or use comments as a research journal.

## Measured complexity

Prefer clear algorithms and data flow. Before keeping an optimization, picture
the unoptimized version: if it is much simpler, require evidence that the
optimization is needed. Optimize demonstrated bottlenecks only.

## References

Read only what the task needs:

- `references/structure.md`: placing code, feature and shared boundaries,
  dependency direction, colocation.
- `references/naming.md`: choosing or reviewing names.
- `references/cognitive-load.md`: simplifying control flow, modules, and
  abstractions.
- `references/dependencies.md`: choosing or adding a library.
