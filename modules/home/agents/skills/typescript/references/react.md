# React

Load this entrypoint only after identifying React in the actual implementation.
Respect the application's rendering model, router, server/client boundaries, and
established state architecture. Do not silently replace them.

## Default implementation posture

- **Feature-first colocation is essential.** Keep feature data access, state,
  components, hooks, and types with their owning capability, not scattered
  across global directories grouped by technical type. Compose features above
  their boundaries; reserve shared modules for genuine cross-feature
  foundations.
- Keep rendering pure and state close to the components that own it. Derive
  display values from props/state rather than store synchronized copies.
- Prefer component composition over a monolithic component controlled by many
  flags. Keep cohesive component logic nearby; extract hooks for a real reusable
  lifecycle or behavior, not merely to move code out of sight.
- Treat **`useEffect` as a code smell to avoid**, not a standard place for
  application logic. Derive values during rendering, handle explicit actions in
  event handlers, and put asynchronous orchestration in the established router,
  query, mutation, or state-machine architecture.
- A narrow exception is lifecycle synchronization with a genuinely external
  system that has no suitable existing integration. Explain the external
  contract and why an effect is needed. Keep dependencies accurate and cleanup
  symmetric; do not suppress lifecycle problems with run-once refs.
- **Avoid `useMemo` and `React.memo` by default.** Manual memoization is not
  prophylactic optimization. First simplify ownership and component boundaries;
  require measured benefit for a performance exception and explain it locally.
  Do not rely on memoization for semantic correctness.
- Do not add `useCallback` to every handler. Use it only for an actual identity
  contract or an evidenced optimization; reconsider avoidable identity coupling.
- Strongly recommend **TanStack Query for React server asynchronous state**. If
  the project has another established solution, implement consistently with it.
  Evaluate a replacement and discuss benefits, migration costs, rendering
  integration, and cache behavior with the operator; obtain confirmation before
  adding dependencies or rewriting existing patterns.

> Avoid an effect that copies a filtered list into state, and avoid wrapping the
> same trivial filtering in `useMemo` automatically. Compute it directly. A
> subscription to an imperative external widget may justify a small effect when
> the existing architecture offers no appropriate adapter.

## Load only the relevant detail

- Feature ownership, horizontal/vertical slices, public APIs and dependency
  direction: [Feature structure](feature-structure.md).
- State ownership, effects, identity, lifecycle and measured performance:
  [State and lifecycle](react-state.md).
- Server reads, mutations, cache identity, typed clients and permission-aware
  UI: [Async data and authorization](react-async.md).
- JSX composition, semantic HTML, layout, accessibility and localized copy:
  [UI implementation](react-ui.md).
