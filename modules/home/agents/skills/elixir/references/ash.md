# Ash

Load this entrypoint only for actual Ash resources, domains, or integrations.
Inspect the installed versions, resource extensions, actions, code interfaces,
authorizers, and data layer before selecting APIs. Project instructions
supplement framework documentation; they do not replace it.

Keep domain operations in resource actions and expose them through the project's
resource/domain interfaces. Carry the actual actor, tenant, and authorization
context through reads, mutations, relationship loads, and delegated work. Do not
disable authorization to make an integration easier.

Actions own their accepted inputs, validations, changes, and invariants. A typed
client or a UI permission map is not a substitute for server enforcement. Keep
stored facts distinct from calculations and aggregates; request only the loads
and fields needed by the caller.

Prefer built-in changes and validations when their contracts fit. Do not weaken
atomic action requirements to accommodate avoidable hook code. Inspect generated
migrations and database constraints rather than assume a relationship
declaration enforces every invariant under concurrency.

## Ash first

Reach for Ash's built-in mechanisms before writing custom processes: changes,
validations, notifiers, calculations, aggregates, atomic updates, and the job
integration the project already uses, such as AshOban. Do not add a custom
GenServer, worker, lock, or polling loop beside them unless they demonstrably
cannot express the behavior; name the missing capability first.

One PostgreSQL instance goes very far, including queues and background jobs.
Exhaust it before adding new infrastructure.

> Send a confirmation email after an invoice is issued from an `after_action`
> change that enqueues a job through the existing job integration, not from a
> GenServer polling for newly issued invoices.

## Domain and resource ownership

Organize **vertical slices by business capability**, using the established Ash
domains and resource roles. Keep related resources under their domain and keep
resource-specific actions, changes, validations, preparations, policies, and
supporting types in the resource or nearby supporting modules. Avoid splitting
all capabilities into global `resources/`, `actions/`, or `types/` buckets.

For example, an established `MyApp.Catalog` domain can own `catalog/product.ex`
and `catalog/product/changes/`; technical subfolders inside an owner are fine
when useful, not mandatory boilerplate. Domains group related capabilities, not
arbitrary file counts; not every resource needs its own domain.

**Horizontal slices** are genuine shared foundations such as actor/tenant
infrastructure, common data-layer integration, or platform adapters. They do not
depend on consuming domains. Compose capabilities through deliberate action and
resource/domain interfaces, not sibling implementation modules; preserve a
directed acyclic module dependency graph. Cross-domain relationships are not
automatically forbidden, but must have explicit ownership and authorization
contracts rather than accidental coupling.

Do not move an existing resource, split a domain, or regenerate interfaces
merely to fit a preferred tree. Obtain operator approval for broader migrations
and preserve module references, domain registration, generated interfaces, and
repository rules. See the installed-version
[Ash project structure guidance](https://hexdocs.pm/ash/project-structure.html)
for framework conventions, not a substitute for inspecting this application.

### Selected existing structure: Firmowid

This selection uses existing filenames; `...` omits unrelated files. It shows
ownership, not a scaffold to generate or a claim that every dependency is ideal.

> ```text
> lib/firmowid/
>   repo.ex                              # shared persistence adapter
>   ash/
>     resource.ex                        # shared timestamp macros
>     scope.ex                           # shared actor/tenant context
>     ...
>     invoicing/                         # vertical capability
>       invoicing.ex                     # Firmowid.Ash.Invoicing domain
>       counterparty.ex                  # registered resource
>       cost_invoice.ex                  # registered resource
>       sales_invoice.ex                 # registered resource
>       sales_invoice_item.ex
>       sales_invoice_test.exs           # existing colocated tests
>       sales_invoice/
>         effective_fields.ex            # resource-specific support
>         email_recipient_eligibility.ex
>         ...
>       changes/                         # support within this domain
>         normalize_counterparty_tax_id.ex
>         ...
>       validations/
>         validate_items_not_empty.ex
>         ...
>       services/
>         ...
>       workers/
>         ...
>       ...
> ```

The domain groups several related resources; a resource's supporting folder is
not a separate domain. Technical directories such as `changes/` and
`validations/` are domain-local here, not application-wide buckets. Resource
macros, scope handling, and persistence are horizontal responsibilities outside
the invoicing owner. The existing layout mixes domain-wide support directories
with resource-specific support; do not move files merely to make it uniform.
Existing colocated tests illustrate this repository's layout, not permission to
add tests where repository rules prohibit them.

## Load only the relevant detail

- Actor/action matrix, ordered checks, read filtering and field access:
  [Policies](ash-policies.md).
- Strong dependencies, weak events, transactions and safe bulk mutations:
  [Actions and dependencies](ash-actions.md).
- Reusable list interfaces, filters and pagination: [List APIs](ash-list.md).
- Blob/attachment ownership, uniqueness and storage lifecycle:
  [Storage](ash-storage.md).
