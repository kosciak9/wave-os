---
name: implementation-design
description: >-
  Apply general implementation design principles when adding or changing code:
  cognitive load, cohesive boundaries, state ownership, abstractions, naming,
  and focused changes. Use for implementation choices independent of language.
---

# Implementation Design

Design for the next person who must understand and change the implementation.
These principles also help assess existing code; they are not a separate review
process or permission to expand the task. Repository instructions and concrete
contracts take precedence over generic preferences.

## Reduce the amount a reader must remember

Make inputs, outputs, failure cases, and side effects visible. Prefer
straightforward control flow over clever compression. Name meaningful decisions,
flatten nesting where the language supports it, and handle invalid states at
their boundary. Do not turn every expression into a helper: indirection also
costs attention.

> Prefer a named eligibility decision to a long boolean expression embedded in a
> template. Avoid a chain of tiny wrappers that makes the reader open five files
> to discover what that decision means.

Keep pure transformations separate from orchestration and external effects when
that distinction makes behavior easier to follow. A small public interface
should hide meaningful complexity, not merely relocate it.

## Cohesion and boundaries

Organize code by ownership and business capability first, technical type second.
**Vertical slices** are cohesive features: keep their data access, state,
components/adapters, types, and helpers together so changing one capability does
not require navigating global directories for every technical category. Use the
repository's established layout; small features need no directory boilerplate.

**Horizontal slices** are genuinely shared foundations with meaningful
contracts: authentication, common data access, platform integrations, or UI
primitives. Share the foundation, not every feature-specific use of it. A
directory named `common`, `lib`, or `auth` is not automatically a foundation;
verify its ownership and consumers. Avoid global `components`, `actions`,
`types`, or `utils` buckets for code that belongs to one feature.

Expose deliberate interfaces between features. Shared foundations should not
depend on their feature consumers. Compose features at the layer that owns their
interaction rather than importing another feature's internal implementation.
Avoid dependency cycles and unrelated responsibilities in one module.

Keep the dependency graph directed and acyclic: composition imports feature
interfaces and foundations; features import foundations and their own internals;
foundations never import consuming features or application composition. Nested
subfeatures belong to their parent, not to arbitrary sibling consumers. Any
necessary cross-capability dependency uses a deliberate public contract, not
sibling internals, and must preserve that graph.

> In a TypeScript backend using tRPC, group routers and their procedures,
> validation, and feature-specific data access by capability; compose those
> routers at the server root. Keep shared context/authentication infrastructure
> below them. Validate inputs and enforce actor, tenant, and record permissions
> on the server; typed clients do not provide runtime authorization. Use the
> project's actual transport and validation APIs, not a new default tRPC stack.
> This structure does not require React or a frontend.

> A feature-local parser can remain beside its caller. Move it to a shared
> module when several real consumers need the same contract, not because another
> consumer might appear someday.

Apply these boundaries to the requested change, not as permission for a layout
migration. Surface existing structural problems and obtain operator approval
before broad moves, dependency changes, or new boundary-enforcement tooling.
Preserve framework discovery, route mapping, and repository test/documentation
rules; colocation does not override them.

## One source of truth

Identify authoritative state before adding a second representation. Derive
values that can be computed reliably from existing inputs. Separate persistent
facts, user intent, temporary drafts, cached results, and presentation
projections.

Stored derived values require a reason and an explicit consistency model:
invalidation, refresh, ownership, and failure behavior. Historical snapshots and
independent drafts are not redundant state when their different meanings matter.

> Store the selected record's identity and derive its current display value.
> Avoid storing a selected record plus a second synchronized copy of its label.
> A draft intentionally allowed to diverge from the saved record is different.

## Use the platform; justify abstractions

Use standard library and platform capabilities, then established project
dependencies, before rebuilding the same mechanism. Check runtime support and
the actual API contract; a familiar name is not proof of compatibility.

Abstractions should hide a stable responsibility or invariant. A little local
duplication is preferable to coupling unrelated behaviors through a configurable
universal helper. Do not add dependencies, caches, queues, services, or future
extension points merely to make the architecture look complete.

> Prefer the existing URL parser to handwritten splitting. Avoid a new routing
> abstraction that forwards every call unchanged and exposes all implementation
> details to its callers.

## Names and useful comments

Use the project's vocabulary and naming conventions consistently. Names should
reveal purpose, value shape, and relevant effects without cryptic abbreviations
or repeating context already supplied by the module. Distinguish a predicate,
transformation, retrieval, and destructive operation.

Comments explain non-obvious invariants, constraints, and justified departures.
Do not narrate obvious syntax, retain obsolete explanations, or use
implementation comments as a research journal. Improve a misleading name rather
than compensate with a paragraph of commentary.

## Focus and measured complexity

Make the requested behavior correct with the smallest maintainable change. Fix
adjacent defects only when necessary for that behavior; surface independent
cleanup separately rather than quietly widening scope.

Prefer clear algorithms and data flow first. Optimize demonstrated bottlenecks,
measure the relevant workload, and keep evidence proportional to the decision.
Do not sacrifice readability for speculative performance gains or impose
arbitrary size thresholds as design laws.

> Removing a redundant synchronization step needed by the feature is in scope.
> Renaming neighboring modules and replacing their state library is not an
> incidental part of adding one control.

Assess the result by whether its ownership, dependencies, state transitions,
security boundary, and failure behavior can be explained locally. Preserve
established project checks and constraints rather than importing a default stack
or a universal verification workflow.
