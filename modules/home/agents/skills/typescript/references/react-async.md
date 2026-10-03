# React Async Data and Authorization

## Choose an owner, not a collection of flags

Strongly recommend TanStack Query for React server async state, rather than
handwritten `useEffect` plus `useState` request machinery. If installed and
established, use its existing query client and feature patterns. If another
router/data/cache solution is established, follow it for the requested change.
Propose replacement separately with benefits, costs, and integration risks;
operator confirmation is required before migration or a new dependency.

Use the correct owner for the operation: server reads belong in the data layer,
user commands in mutations/actions, and device permissions or long-running flows
in the established interaction architecture. Do not force every timer,
animation, or permission prompt into an automatically refetching server query.

Model initial loading, empty success, errors, successful data, and background
refresh distinctly. Keep useful prior data visible when appropriate, and show
refresh failures without pretending cached data is a fresh success. Consider
cancellation, stale responses, retry safety, and duplicate submissions.

## Cache and typed transport boundaries

- Include every data-changing input in cache identity: filters, sort,
  pagination, and relevant account/tenant scope. Never put credentials in cache
  keys. Follow established cache isolation/reset behavior on identity changes.
- Request only needed fields using generated selection/result types where
  available. Reuse real client adapters for headers, transport errors, and
  result unwrapping; inspect their contract instead of inventing a helper API.
- Keep transport failures observable by the async manager. Do not catch a failed
  request and return an empty collection as if the server succeeded.
- If the project uses client-side collections, keep record identity stable and
  derive joins/projections from their source collections. Handle every mutation
  in a batch, not just the first. Use an established bulk endpoint when its
  semantics fit; do not invent one or assume client batching is server
  atomicity.
- Send only intended create/update fields. Invalidate or update affected caches
  through existing patterns after confirmed success. Optimistic changes need
  explicit rollback and conflict behavior; do not optimistically claim an
  irreversible command succeeded.
- Use Suspense only within the project's adopted data/boundary integration. Do
  not silently convert loading and error architecture while adding a feature.

> A list filtered by status and page needs both inputs in its cache identity.
> Avoid sharing one cache entry for differently scoped results or converting a
> forbidden response into `[]` to conceal the failure.

## Permission-aware UI is not authorization

The server remains the security boundary for every read and command. Route
guards and hidden controls improve UX but cannot enforce access. Reuse the
project's permission source and route requirements instead of duplicating rules
at each link. Default protected interactions closed while permission data is
unknown.

Guard the whole meaningful interaction, not just its decorative label. Continue
to handle server denials because permissions may change or cached capability
data may be incomplete. A capability check without a record or action inputs
cannot prove record-, argument-, or field-dependent authorization.

Filtered server reads can legitimately return fewer rows without forbidding the
whole action. Do not treat an executable filtered query as proof that every
route, record, or operation is allowed. Preserve the backend's information
disclosure contract rather than changing it to simplify a frontend boolean.
