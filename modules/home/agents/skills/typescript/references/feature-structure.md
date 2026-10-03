# Feature Structure

Use this reference for React feature boundaries and colocation decisions, not as
a mandatory stack or permission to reorganize an application. Inspect the actual
router, rendering model, packages, transport, and import conventions first.

## Ownership before technical type

**Vertical slices** group code by the capability it implements. A feature owns
its data reads/mutations, cache keys, local state, components, hooks, types,
validation, styles, and helpers. Technical categories may organize a large
feature internally; they should not scatter that feature across application-wide
`components/`, `hooks/`, `stores/`, `api/`, and `types/` directories.

**Horizontal slices** provide genuinely shared foundations: UI primitives,
authentication/session infrastructure, a common data client, or platform
adapters. Keep these small, cohesive, and independent of consuming features.
Authentication can also have a vertical sign-in feature; its UI is not the same
boundary as shared session infrastructure. Likewise, a common client does not
own every feature's queries or business rules. `common/` is not a dumping
ground.

### Example: employee recruitment application

The following illustrative tree shows one way to organize an employee
recruitment application. `...` omits unrelated files.

> ```text
> apps/
>   next/app/(with-navigation)/recruitment/[openingId]/
>     page.tsx                           # web route adapter
>   expo/app/(tabs)/recruitment/[openingId]/
>     index.tsx                          # native route adapter
>   ...
> packages/
>   app/
>     lib/
>       trpc.ts                          # shared typed client context
>       get-trpc-client.ts
>       get-trpc-client.web.ts
>       ...
>     providers/
>       trpc-provider.tsx
>       safe-area/
>         use-safe-area.ts
>         use-safe-area.web.ts
>         ...
>       ...
>     features/
>       common/                          # existing shared helpers/UI
>         components/
>           ...
>         hooks/
>           ...
>         ...
>       recruitment/                     # vertical capability
>         recruitment-screen.tsx         # consumed by both route adapters
>         atoms/
>           selected-candidate-atom.ts
>           ...
>         components/
>           ...
>         hooks/
>           use-opening-from-params.tsx
>           ...
>         utils/
>           ...
>         features/
>           candidate-profile/           # nested owner, not a sibling API
>             components/
>               candidate-profile.tsx
>               activity-chart.tsx
>               activity-chart.native.tsx
>               ...
>             hooks/
>               ...
>             types/
>               index.ts
>               ...
>             utilities/
>               ...
>         ...
>       ...
>     ...
>   ui/src/                              # shared UI package
>     ...
>   ...
> ```

Both platform routes consume the same feature screen; route adapters handle
framework-specific integration, while the feature owns its state, hooks,
components, and nested candidate-profile subfeature. Client/provider and UI
packages illustrate horizontal responsibilities, not separate business owners.
Shared code under `features/common/` still needs a cohesive boundary; the name
alone does not establish one. This example does not prescribe a new `shared/`
directory.

A tiny feature may be one or two files. Add `api/`, `atoms/`, `hooks/`, or
nested subfeatures only when the existing architecture and actual complexity
warrant them. Do not create unused folders, duplicate generated types, or
install the libraries from a reference project's stack. A monorepo's `apps/` and
`packages/` split does not replace feature ownership inside each relevant
package.

## Public feature API and composition

Expose only what outside consumers need: a screen, focused component, operation,
or stable contract. Keep implementation components, cache details, internal
state, and one-off hooks private to the feature. A public API is a deliberate
import boundary, not necessarily a barrel file. Follow the project's export
conventions and bundler constraints; do not re-export all internals through
`index.ts` or introduce barrels merely for aesthetics.

Compose independent features in routes, screens, or another explicit parent
layer. Pass data and callbacks through their contracts instead of letting one
feature reach into a sibling's store, query implementation, or component tree.
Nested feature blocks belong to their parent; they are not freely shared sibling
internals. When an established cross-feature dependency is necessary, make its
public contract explicit and preserve an acyclic graph.

Import direction is `app/composition -> features -> shared foundations`;
composition may also import foundations directly. Foundations never import their
consuming features, and features do not import application composition. Use
existing boundary checks when available; adding lint rules or restructuring
packages requires scope and operator agreement, not incidental cleanup.

## State, hooks, and reusable boundaries

Keep state at the narrowest owner that must coordinate it. Feature-wide state
does not automatically belong in a global store. Put server-state query options,
mutations, and cache identity with the feature even when they use a shared
client. Keep component-specific logic in or beside that component; extract a
hook for genuinely reusable behavior or a lifecycle contract, not to hide all
feature logic behind one oversized hook.

Promote code to a horizontal foundation when real consumers need the same stable
contract, not because two components happen to look similar. Shared UI should
not import feature state or perform capability-specific business operations.
Preserve the React entrypoint's effect, memoization, and server-state guidance;
moving code into a hook does not justify new synchronization or state copies.

## Transport and server ownership

Use the actual project client and transport. If tRPC is present, server routers
can follow domain/feature boundaries, with procedures, input validation, and
feature-specific data access nearby; the root router composes their public
interfaces. Shared context and authentication middleware are foundations, not
reasons to put all operations into global technical buckets.

Authentication, tenant scoping, input validation, and record-level authorization
remain server-owned. A protected procedure or typed client alone does not prove
that a particular operation is authorized. Frontend feature queries consume that
contract without importing server implementation or secrets. Do not install
tRPC, a schema library, or a new state stack just to match this structure.

### Example: recruitment server ownership

This illustrative server tree shows domain-based router ownership. The frontend
recruitment feature corresponds to these server capabilities, but its nested UI
ownership does not require identical server nesting.

> ```text
> packages/server/src/
>   index.ts                             # exports router and its type
>   router.ts                            # root composition
>   trpc.ts                              # shared context/procedure setup
>   db/
>     ...
>   lib/
>     ...
>   router/
>     candidates/
>       router.ts                        # composes feature procedures
>       procedures/
>         list-candidates.ts
>         ...
>       types/
>         index.ts
>       utilities/
>         ...
>       ...
>     applications/
>       router.ts
>       procedures/
>         get-application.ts
>         upsert-application.ts
>     openings.ts                        # compact single-file router
>     ...
>   ...
> ```

The root composes capability routers, while larger capabilities keep procedures,
types, and utilities inside their owner. A compact capability can use a
single-file router; do not manufacture empty procedure folders where they add no
value. Shared context and database infrastructure remain outside those owners.
The frontend client imports the exported router **type**, not server procedure
implementations. Keep cross-capability dependencies explicit through stable
contracts, and check authorization at the server boundary.

## Existing code and scope

Improve ownership within the requested change. Do not indiscriminately move
existing files, rename features, or migrate transport/state architecture. Obtain
operator approval for broader migration and discuss import paths, route
discovery, server/client boundaries, and compatibility before moving code.
Preserve framework-required route files as adapters/composition points and
respect repository restrictions on tests and documentation.

## Primary sources

- [Bulletproof React project structure](https://github.com/alan2207/bulletproof-react/blob/master/docs/project-structure.md)
- [tRPC router composition](https://trpc.io/docs/server/merging-routers)

Apply the ownership principles, not every example directory, library, test
placement, or documentation recommendation in these sources. Repository rules
and actual runtime boundaries take precedence.
