# Ash Policies

## Start from the actor/action matrix

Inventory read, create, update, destroy, and custom actions. Define expected
allow and deny outcomes for anonymous, ordinary, privileged, and relevant
service actors. Include cross-owner/tenant attempts, record-dependent decisions,
input-dependent decisions, relationship loads, and sensitive fields. Use the
application's actual actor model rather than inventing a privileged system-role
helper.

## Encode a decision deliberately

- Policy conditions decide whether a policy applies. All applicable regular
  policies must pass, unless an applicable bypass changes that requirement.
- Checks within a policy logically apply top to bottom: the first explicit
  authorization or prohibition decides that policy. No authorization means deny.
  This is logical ordering, not a promise of physical callback execution order.
- Multiple `authorize_if` checks express alternative allow paths, not a set of
  requirements that must all hold. Put mandatory prohibitions before an allow
  that would otherwise decide the policy too soon.
- Keep bypasses rare, explicit, and ordered intentionally. Inspect which
  policies they bypass; do not use one as a convenient fix for an incomplete
  matrix. Policy groups cannot contain bypass policies.
- Describe complex intent and keep check implementations free of side effects.
  Do not split a coherent decision into interacting policies accidentally.

> If an inactive actor must never edit, a deny for inactivity belongs before an
> ownership allow in the same policy. Two consecutive ownership and role allows
> do not require both ownership and that role.

## Read filtering versus action refusal

The default `:filter` access type filters read results. A list can be empty or
reduced, and an inaccessible single record can look missing instead of
forbidden. Preserve that information-disclosure boundary. `:strict` requires
checks to be resolved statically and forbids when they are not met; use it when
an action-level allow/deny contract is intended and the checks can express it.

Do not change every read to strict merely to simplify route guards. A capability
check may permit executing a filtered action without proving access to any
particular row. A check lacking record/input context cannot establish a record-,
argument-, or field-specific permission. The executing action must still
authorize with the actual actor and inputs.

Use runtime checks only when the rule cannot be expressed safely at an earlier
stage and the installed version/data layer supports the necessary lifecycle.
Relationship loads may be filtered to `nil`, fail the request, or yield
`Ash.ForbiddenField` according to policy and relationship options. Callers must
handle the configured behavior, not interpret every missing relation as corrupt
data.

## Version-sensitive and field-sensitive rules

Verify create-filter behavior against the locked Ash version. Recent releases
support some record-dependent create filters through post-insert authorization
inside a transaction; older guidance may prohibit them. Check data-layer
support, action transaction settings, and hooks outside rollback protection.
Never assume preflight authorization can see a record that has not been created,
or that external side effects roll back with it.

Where a policy means existence of related data, consider `exists/2` rather than
relationship predicates that unintentionally constrain the same joined row when
combined. Verify the intended relationship/filter composition.

Adding field policies requires deliberate coverage of readable fields; primary
keys have special treatment, and private-field behavior has its own
configuration. A catch-all is a security decision, not boilerplate. Field
policies do not replace action policies. Examine aggregates/calculations and
serialized results for indirect disclosure, and handle forbidden-field values
explicitly.

Validate the matrix through the project's permitted verification paths. Keep
authorization diagnostics out of user-visible responses; do not expose private
record or actor details while investigating a denial.
