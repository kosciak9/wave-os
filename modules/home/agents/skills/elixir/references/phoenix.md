# Phoenix

Load this entrypoint only when the implementation actually uses Phoenix. Follow
the installed version and established router, context/domain, component, and
authentication boundaries. Keep web modules responsible for transport and
interaction rather than duplicating domain rules or bypassing domain interfaces.

Treat request parameters, sessions, LiveView events, and upload metadata as
untrusted inputs. Authenticate and authorize on the server for reads and
commands, including connected interactions. Hiding a button or authenticating a
route does not authorize the event or record it targets.

Keep LiveView assigns as small as the interaction needs. Distinguish
authoritative data, form drafts, and derived presentation. Avoid storing
redundant projections that each callback must synchronize. Reuse existing form
and component adapters, and keep long-running work in the application's
supported async/job mechanisms.

Use function components and slots for composition; introduce a stateful
component only when it owns meaningful lifecycle or interaction state. Keep
templates readable and feature-specific behavior near its owner. Preserve
deliberate URL contracts rather than importing another application's route
vocabulary.

## Feature boundaries in the web layer

Use **vertical business-capability slices** in contexts/domains and keep their
web adapters cohesive within the established `*_web` layout. A feature's
LiveViews, associated HEEx templates, forms, and feature-only components belong
near that feature's web owner, not in unrelated global helper buckets. Preserve
the framework's business/web separation: adapters call context/domain public
interfaces; contexts do not import their web consumers or transport internals.
When Ash is present, those interfaces should retain resource action ownership,
not duplicate the same invariants in a Phoenix context wrapper.

Keep **horizontal foundations** such as authentication infrastructure, shared
layouts/components, and platform adapters genuinely reusable and independent of
feature consumers. Compose features at their owning page/router/orchestration
layer, never through sibling LiveView assigns or private helper modules. Keep
dependencies directed and acyclic; explicit cross-context public contracts may
be appropriate, but sibling internals are not shared APIs.

Retain established router scopes, pipelines, `live_session` boundaries, module
names, and route-to-module mapping. Feature colocation does not authorize moving
every controller or LiveView into a new tree. Obtain operator approval for broad
layout changes and preserve framework discovery and repository
test/documentation rules. The
[Phoenix context guide](https://hexdocs.pm/phoenix/contexts.html) explains
business boundaries; adapt conventions to the installed version.

### Selected existing structure: Firmowid web adapters

Existing filenames below show the web side of the invoicing capability; `...`
omits unrelated files. This is a selection, not a proposed migration.

> ```text
> lib/firmowid_web/
>   core/
>     endpoint.ex
>     router.ex                          # route composition
>     ...
>   design_system/
>     components/                        # shared presentation foundation
>       ...
>     utilities/
>       ...
>   invoicing/                           # feature-owned web adapters
>     form_helpers.ex
>     sales_invoices/
>       components/
>         invoice_items.ex
>         invoice_payment.ex
>         ...
>       controllers/
>         ...
>       utilities/
>         ...
>       views/
>         edit.ex                        # LiveView
>         edit.html.heex
>         edit_test.exs                  # existing colocated test
>         ...
>     ...
>   ...
> ```

The vertical owner spans business modules under `lib/firmowid/ash/invoicing/`
and transport/presentation modules under `lib/firmowid_web/invoicing/`; it does
not collapse Phoenix's business/web separation. The editing LiveView uses Ash
resource/domain interfaces and feature-local form/component helpers. Endpoint
and router composition live outside the feature, as do shared design-system
components. These directories illustrate responsibilities, not proof that all
existing helpers or imports satisfy the ideal boundary. Preserve the actual
`views/` naming, route mapping, and colocated test convention rather than
renaming them to match another application's `live/` or `test/` tree.

## Load only the relevant detail

- HEEx structure, accessible interactions, layouts and localized copy:
  [UI implementation](phoenix-ui.md).
- Behavior-focused LiveView validation and test-helper boundaries:
  [LiveView testing](phoenix-testing.md).

These references do not override repository restrictions on adding tests or
documentation, or mandate another project's fixtures and infrastructure.
