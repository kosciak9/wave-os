# React State and Lifecycle

## Remove synchronization before adding it

Identify the authoritative owner of each value. Derived counts, labels, filtered
lists, and eligibility decisions belong in render-time calculations. Keep user
drafts distinct from saved server data; do not repeatedly overwrite an edited
draft whenever a query refreshes.

> Prefer `const visibleRows = rows.filter(matchesFilter)` during rendering.
> Avoid `useEffect(() => setVisibleRows(rows.filter(matchesFilter)), [rows])`:
> it creates a second owner, a stale render, and a synchronization obligation.

Store minimal user intent, such as a selected identity, and derive the current
record from the authoritative collection. Reset a whole editing subtree with a
deliberate identity/key boundary when it represents a different entity. Do not
randomize keys or use position as identity for reorderable records.

## Explicit actions, not effect chains

Submit, save, navigation, and action-specific notifications belong with the
event or mutation that caused them. Coordinate related transitions in the
established reducer/state-machine architecture when needed. Avoid setting a flag
merely so an effect notices it and starts work. Moving such an effect into a
custom hook does not cure its ownership problem.

An effect is an escape hatch for external synchronization, not permission to
implement server fetching by hand. Prefer purpose-built integrations for
external stores and the established async data layer for requests.

If an external widget or subscription genuinely requires an effect:

- State why its lifecycle must track the mounted component.
- Keep each effect responsible for one external synchronization contract.
- Include reactive dependencies honestly; restructure rather than suppress
  dependency checking or freeze a stale closure.
- Pair setup and teardown for listeners, subscriptions, timers, and resources.
  Ensure remounts and development lifecycle checks do not duplicate work.
- Prevent stale completions from updating a newer instance or identity.

> A widget connection with a matching disconnect is a lifecycle contract. A
> chain of effects that updates a total, then eligibility, then submits a form
> is application orchestration and should be redesigned.

## Memoization is exceptional

Do not add `useMemo` or `React.memo` by default, including for inexpensive
calculations, object literals, or every shared component. Do not use them to
silence dependency warnings. A measured expensive calculation or rerender may
justify a focused exception after moving state closer to its owner and improving
composition. Explain the bottleneck and verify the gain under a representative
production workload.

`useCallback` is not a blanket requirement for event handlers. If a consuming
API truly needs stable function identity, document that contract and preserve
correct captured values. Do not build a dependency ladder of callbacks and memos
merely to support another avoidable effect.

Inspect whether the project already uses compiler-managed optimization before
introducing manual layers. Optimization must never be required for correctness.
