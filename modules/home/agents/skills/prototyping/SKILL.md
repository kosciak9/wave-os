---
name: prototyping
description:
  "Builds a quick runnable spike to check feasibility. Use when the user asks to
  quickly try, test or wire something up end-to-end rather than discuss it."
when_to_use:
  "'przetestuj szybko czy da się', 'zrób szkic', 'spike', 'proof of concept',
  'podepnij X do Y na próbę'."
---

# Prototyping

## When to use

Use a prototype to make a chosen idea concrete quickly, inspect its behavior,
and check feasibility. The direction may already be known, or several prototypes
may help compare approaches. Prototyping is an independent technique, not
inherently discovery or a mandatory step before ordinary implementation.

> Example: connect a chat interface, an MCP tool, and an app's UI in one minimal
> end-to-end flow to see whether the intended interaction works.
>
> Counterexample: introduce a disposable implementation for an obvious fix that
> can be made and verified directly in the existing system.

## Define the question and smallest useful slice

State what the prototype should show, which behavior matters, and what is
outside scope. Choose the smallest representative end-to-end path that can
answer the question, not a collection of disconnected components that only
appear to fit. Stop adding features once the slice provides the needed evidence.

Use existing code or traces instead if they already answer the question. A
prototype is useful when making the idea runnable adds information, not merely
because new code is easy to write.

> Example: exercise one real request through the UI, tool invocation, and
> visible result before adding more workflows or configuration options.
>
> Counterexample: build the complete product before checking whether its central
> integration can work.

## Favor speed and inspectability over polish

Consciously rough, hardcoded, duplicated, or deliberately extreme code is fine
when it makes the idea faster to realize, easier to inspect, or simpler to
change. Prefer a disposable slice that exposes the mechanism over abstractions
that hide it or make variants expensive to try. Do not build a reusable
framework merely to make temporary code look production-ready.

Make inputs, intermediate states, decisions, outputs, and failures inspectable
at the level needed to answer the question. Roughness must not make results
unreadable or unreliable. Keep enough evidence to know what ran and what
happened before changing or discarding the prototype.

> Example: duplicate a small runner for two variants so their differences stay
> explicit rather than first building a configurable framework.
>
> Counterexample: spend an iteration polishing code that the next trial may
> invalidate, while its actual behavior remains hard to inspect.

## Keep feasibility claims honest

Stub incidental details when useful, but exercise the critical boundary for the
question. A mocked boundary cannot establish that the real integration is
feasible. If access or safety prevents testing it, report that limit rather than
presenting the prototype as proof.

Separate tested facts from stubbed behavior, assumptions, and interpretations.
Record the cases and conditions actually exercised; one successful path does not
establish reliability, scale, security, or production readiness. A focused trial
can validate a known direction without requiring broad exploration.

> Example: a simulated tool response verifies UI rendering, but only a real tool
> invocation can establish that the intended call and result exchange work.
>
> Counterexample: claim end-to-end feasibility after mocking the very boundary
> whose compatibility was in doubt.

## Decide whether to discard or adopt

Make the outcome explicit: discard the idea, continue within the agreed scope,
or propose adopting it with its evidence and remaining limits. Existing code is
not a reason to keep investing in an unhelpful direction.

If adopted for production, clean up and refactor the rough implementation or
replace it before production merge, and verify the resulting production
behavior. A discarded prototype needs no cleanup for its own sake; remove your
temporary artifacts as required without polishing code that will not be used.

> Example: the integration works; propose adoption, then replace hardcoded
> values and duplicated paths before merging the authorized production
> implementation.
>
> Counterexample: merge a successful disposable demo unchanged, or refactor a
> rejected prototype merely because effort has already been spent on it.

## Stay within authorization and safety boundaries

Work autonomously within the agreed prototype scope without asking permission
for every local iteration. A request to prototype does not automatically permit
production implementation, merge, or deployment. Return for agreement when the
next step changes the scope or requires additional authorization.

Follow repository and host safety rules even in disposable environments. Protect
secrets, external systems and resources, irreversible operations, and other
people's work. Remove only your own temporary artifacts; do not disturb
unrelated changes or resources to make the prototype easier to run.
