# Ash Actions and Dependencies

## Strong dependencies are explicit atomic work

If the source operation is invalid without the dependent operation, orchestrate
both through the established domain/action orchestration in one supported
transaction. Propagate failures so either both commit or both roll back. Verify
the actual data layers, repositories, process boundaries, and transaction API
for the installed version; two individually transactional actions are not
automatically one atomic operation.

> Creating a record and a required companion record is one atomic operation.
> Broadcasting an event and hoping a listener creates the required companion
> later does not preserve that invariant.

Database rollback cannot undo remote requests or arbitrary process messages.
Keep irreversible side effects outside uncommitted or potentially unauthorized
work. Choose established orchestration, durable handoff, or compensation when
the boundary crosses systems; do not claim a database transaction solves it.

## Weak dependencies are reactions

If the source remains valid when its reaction fails, use the application's event
or job architecture. Keep payloads minimal and stable, usually identities plus
necessary event context. Consumers reload current data rather than rely on broad
resource snapshots, unless the requirement genuinely needs historical event
data.

The consuming domain owns its reaction. Keep listeners lightweight and delegate
expensive work to the established worker mechanism. Handle duplicate delivery,
retries, ordering, and missing records deliberately. Missing data may be a safe
no-op for cleanup but a real failure for other operations.

PubSub alone is not durable delivery. If losing a reaction is unacceptable, use
the project's transactional job/outbox pattern rather than assume broadcasting
after a write guarantees it. Confirm commit timing and rollback behavior before
choosing a hook. Do not cargo-cult a blanket ban or recommendation for a hook
from another project's architecture.

## Mutations and bulk precision

Prefer authorized Ash action interfaces for domain writes, including bulk work
where supported. Supply actor/tenant context and inspect the bulk result and
error contract. Batching, atomic execution strategies, and all-or-nothing
transactions are different concepts; verify transaction scope and whether
partial success is possible before choosing behavior.

For direct Ecto code, use the actual typed schema and changeset/action paths
appropriate to the application. `Repo.insert_all` with a schema performs schema
type handling but does not run changeset validations or Ash actions/policies. Do
not call it a validated or authorized action substitute. Check timestamp and
identifier generation explicitly; follow the existing types and ID convention
rather than mandating one UUID version everywhere.

Before an operational mutation, confirm the authorized environment and precise
target set. Preview scoped identities/counts, preserve invariants with
constraints and appropriate transaction/isolation behavior, then verify returned
counts and persisted outcomes. Counts alone do not prove the correct rows
changed. If a tool errors after possible execution, inspect state before
retrying.

Raw SQL is a deliberate low-level exception, not the default way around domain
rules. Parameterize values, scope the target precisely, and account for skipped
validation, authorization, defaults, and side effects. This guidance grants no
permission to mutate production or bypass operational approval.
