# Ash List APIs

Prefer a reusable list action with composable optional filters for queries that
share an authorization and result contract. Keep reusable query mechanics in the
resource/domain boundary and caller-specific combinations at the call site.
Avoid multiplying workflow-named list actions that differ only in a filter.

Distinct authorization, semantic operations, or result contracts can justify
separate actions. Do not force every read into one universal list API with flags
that obscure those differences.

Use the project's resource/domain code interfaces from application callers. They
provide a discoverable contract for action inputs, actor/tenant options, loads,
and errors. Do not scatter direct `Ash.read`/`Ash.read!` execution through UI
and service callers when the established interface owns that operation.
Low-level framework adapters may legitimately build and execute queries; keep
that exception at its actual boundary.

## Filters are query inputs, not authorization

Policies must protect access even if the caller omits, changes, or broadens a
filter. Do not depend on a frontend-supplied owner or tenant filter for
isolation. Carry the real authorization context through the action
independently.

> A caller may request only active records, but removing that filter must not
> reveal records owned by someone else. A list argument narrows the result; the
> policy defines what the actor is allowed to see.

Validate external filter/sort inputs and use the framework's input-aware query
facilities where appropriate to preserve field/relationship authorization. Do
not turn arbitrary client keys into unchecked internal expressions.

Define ordering and pagination deliberately. Use a stable tie-breaker where
needed, preserve page/cursor result shapes, and load only required fields and
relationships. Do not fetch the whole dataset and apply security or pagination
afterward in memory.

Keep client cache identity aligned with filter/sort/page and relevant scope.
Check empty results, unauthorized reads, missing required inputs, invalid
filters, and boundary pages using the project's permitted validation methods.
