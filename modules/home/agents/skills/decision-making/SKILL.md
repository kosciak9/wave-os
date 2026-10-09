---
name: decision-making
description:
  "Procedure for choosing between alternatives and recording agreed decisions.
  Use when the user asks for your opinion on an approach, or when a task needs a
  choice about scope, behavior, security, cost or reversibility."
when_to_use:
  "'co sądzisz o X?', 'X czy Y?', 'warto?', 'czy zrezygnować z X na rzecz Y',
  trade-off questions."
---

# Decision Making

## Working assumptions and material choices

- Mark low-impact, reversible working assumptions as `[ASSUMPTION]` and
  continue.

  > Example: use a provisional label in a planning sketch when it does not
  > affect compatibility or user-visible behavior.

- Mark unresolved choices that materially affect scope, user-visible behavior,
  security, cost, or reversibility as `[QUESTION]`. Resolve them with the user
  before treating them as agreed requirements.

  > Example: ask whether skills should be installed globally or only for one
  > project instead of silently choosing their scope.

## Make speed and quality trade-offs clear

Treat speed versus thoroughness as an additional dimension when discussing
decisions, alongside the other constraints relevant to the user's goal. When a
change can be delivered quickly within the current structure or through a more
thorough approach that takes longer, explain the trade-off to the user. Show
what the faster option leaves unresolved and what the additional work would
improve. Do not assume that either speed or thoroughness is always the priority.

Keep a coherent end state on the table, even when it requires a migration or
refactor. Help the user choose based on their goal rather than silently choosing
the quickest fix or the largest redesign.

> Example: "We can add another installer quickly, but that leaves two places to
> maintain. Extracting a shared module takes longer and requires updating the
> imports, but gives us one source of truth."
>
> Counterexample: insist on a broad refactor for a temporary workaround, or
> choose a quick patch without explaining the maintenance cost.

## Settled decisions

Do not reopen settled decisions without new evidence or a change in the user's
intent.

> Example: after agreeing on global installation, carry that decision into later
> planning instead of repeatedly asking about project scope.
