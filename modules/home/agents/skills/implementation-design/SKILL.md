---
name: implementation-design
description:
  "Use when changing code, configuration or infrastructure. Follow the user's
  implementation process: investigate reuse first, keep scope small, own state
  clearly, and justify new mechanisms."
when_to_use:
  "'popraw', 'zaimplementuj', 'dodaj', 'refaktor', 'skonfiguruj', any edit to
  source or configuration files."
---

# Implementation Design

Follow these implementation preferences alongside the project's concrete
contracts and conventions. They do not authorize unrelated cleanup or redesign.

## Before writing code

Inspect the existing implementation and check, in order, the platform/framework,
installed dependencies, and repository infrastructure for the needed capability.
Verify against the installed version's documentation or source, not memory.
Reuse those mechanisms and write only missing glue; explain the actual gap
before building a replacement.

## Grow what exists

Push the existing approach until it becomes genuinely cumbersome before adding
an abstraction or service. When something new is justified, prefer a code
change, then a schema change, then a library, then owned infrastructure, and an
external service last. When the user requests a new design, compare alternatives
rather than treating the current architecture as a requirement.

## Scope

Make the smallest maintainable change. Do not add speculative options,
fallbacks, retries, locks, workers, extension points, or guards for impossible
data shapes. Fix adjacent defects only when necessary; surface independent
cleanup separately.

## Reduce the amount a reader must remember

Make inputs, failures, and side effects visible. Prefer direct control flow and
meaningful, deep interfaces over clever compression or many wrappers. A little
duplication is preferable to a speculative universal abstraction.

## One source of truth

Keep one authoritative owner for state. Derive values when possible; persist
derived state only for a demonstrated need and with a consistency model.
Distinguish durable facts, user intent, temporary drafts, caches, and views.

## Names and comments

Use the project's vocabulary and naming style. Explain non-obvious invariants
and trade-offs in comments, not the code's obvious steps or a research diary.

## Measured complexity

Before keeping an optimization, compare it with the simpler implementation and
require evidence of the bottleneck.

## References

Read only what the task needs:

- `references/structure.md`: placing code, feature and shared boundaries,
  dependency direction, colocation.
- `references/naming.md`: choosing or reviewing names.
- `references/cognitive-load.md`: simplifying control flow, modules, and
  abstractions.
- `references/dependencies.md`: choosing or adding a library.
