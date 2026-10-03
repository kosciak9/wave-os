# Ash Storage Boundaries

Load this detail for file/blob attachment work. Confirm the installed storage
extension, generated resources/actions, and data-layer migrations before using
extension-specific DSL. Do not assume all versions generate the same
constraints.

## Files and ownership are separate

Blob metadata describes the stored object: key, filename, media type, size,
checksum, service, and analysis information as applicable. An attachment relates
that blob to a domain owner and an attachment purpose/name. Authorization for
attaching, downloading, replacing, and deleting follows domain ownership;
knowing a blob identity is not permission to read or attach it.

Add only owner relationships required now. Keep storage service mechanics
separate from domain policy. Never persist credentials in blob service metadata,
expose them in signed-link responses, or commit credential files.

## Enforce actual invariants

A has-one declaration describes relationship semantics; inspect whether
generated actions and database constraints enforce one active attachment per
owner/name under concurrency. If that invariant is required, enforce it at the
database boundary using the project's supported resource identity/constraint
mechanism.

> Uniqueness for one avatar attachment should not accidentally prohibit multiple
> attachments under a separate gallery name. Inspect the generated constraint's
> scope rather than infer it from a `has_one` label.

Choose conditional uniqueness when only some attachment names are singular.
Verify nullable owner keys, deletion references, and generated partial-index
predicates against the installed data layer. Prefer resource identities for
resource-level uniqueness where supported. Add other indexes for demonstrated
access patterns rather than every metadata column.

## Lifecycle and verification

Separate detaching a reference from purging a stored object. Shared blobs and
retrying cleanup require explicit ownership, reference checks, and idempotency.
Database transactions cannot atomically roll back object-store writes/deletes;
follow the established staging, finalization, and orphan-cleanup design.

Validate untrusted upload size/content and access on the server. Check
replacement races, failed upload/finalization, unauthorized download, stale
references, and cleanup behavior through the project's chosen test/runtime
mechanisms. Inspect generated migrations and snapshots with the actual project
commands. Do not impose a particular provider, test service, bucket layout, or
secret workflow.
