# Structure and Boundaries

Use this reference when deciding where code lives, what a module exposes, and
which way dependencies point. It describes a target, not permission for a layout
migration.

## Goals

Structure the code so that:

- working on one capability does not require understanding the whole codebase;
- things that change together live together;
- coupling between modules stays low and deliberate;
- each module can be treated as a black box: a reader at any point of the
  dependency tree sees its inputs and outputs, not its composition,
  dependencies, or algorithms.

## Vertical and horizontal slices

Organize code by ownership and business capability first, technical type second.
**Vertical slices** are cohesive features: keep their data access, state,
components/adapters, types, and helpers together so changing one capability does
not require navigating global directories for every technical category. Whether
the work concerns API calls or local state, if it concerns the same feature it
stays in the same directory or very close to it. Use the repository's
established layout; small features need no directory boilerplate.

**Horizontal slices** are genuinely shared foundations with meaningful
contracts: authentication, common data access, platform integrations, or UI
primitives. They usually live near the root under directories named for the kind
of code they hold, stay as atomic as possible, and never import from features.
Share the foundation, not every feature-specific use of it. A directory named
`common`, `lib`, or `auth` is not automatically a foundation; verify its
ownership and consumers. Avoid global `components`, `actions`, `types`, or
`utils` buckets for code that belongs to one feature.

A feature is a unit that addresses a specific problem or provides specific
value, and should be as independent as possible. Features can be composed from
smaller features, but those building blocks belong to their parent and are not
used outside it. A well-structured codebase therefore forms a tree of features
whose root is the application's entry point.

## Interfaces and dependency direction

Expose deliberate interfaces between features. Shared foundations do not depend
on their feature consumers. Compose features at the layer that owns their
interaction rather than importing another feature's internal implementation.
Avoid dependency cycles and unrelated responsibilities in one module.

Keep the dependency graph directed and acyclic: composition imports feature
interfaces and foundations; features import foundations and their own internals;
foundations never import consuming features or application composition. Nested
subfeatures belong to their parent, not to arbitrary sibling consumers. Any
necessary cross-capability dependency uses a deliberate public contract, not
sibling internals, and must preserve that graph.

> In a TypeScript backend using tRPC, group routers and their procedures,
> validation, and feature-specific data access by capability; compose those
> routers at the server root. Keep shared context/authentication infrastructure
> below them. Validate inputs and enforce actor, tenant, and record permissions
> on the server; typed clients do not provide runtime authorization. Use the
> project's actual transport and validation APIs, not a new default tRPC stack.
> This structure does not require React or a frontend.

Split code into separate packages or applications only when necessary, for
example for separately deployed artifacts, compilation performance, or
incompatible build settings. Separation for its own sake is maintenance burden.

## Colocation

Place code as close as reasonable to where it is relevant. Ask: "If I change
this, where else must I look?" and minimize that number of places. Colocated
code is easier to find, harder to forget when the implementation changes, and
easier to delete together with the feature that used it.

- **State** lives close to where it is used. Lifting it "just in case" creates
  hidden dependencies and obscures data flow; keep it local until something
  actually needs to share it.
- **Utilities** stay in the file or feature that uses them until several real
  consumers need the same contract. Extract after feeling the pain of
  duplication, not in anticipation, to avoid orphaned helpers and dead code.
- **Components** stay with their templates, styles, and hooks. Custom hooks live
  beside the components that use them, not in a central `hooks/` directory.
- **Domain logic** for one entity or context stays in one module or clearly
  related files rather than being split across directories for the sake of
  separation.

> A feature-local parser can remain beside its caller. Move it to a shared
> module when several real consumers need the same contract, not because another
> consumer might appear someday.

### Where tests live

Write tests only when asked or when repository rules require them. When tests
are written, place them beside the code they verify, following the language's
conventions, so that changing a module makes its tests immediately visible:

> ```text
> user.ts
> user.test.ts
> Button/
>   Button.tsx
>   Button.module.css
>   Button.test.tsx
> ```

When the toolchain requires a separate test tree, as Elixir's `test/` directory
does, mirror the source path so the counterpart is obvious:
`lib/app/users/user.ex` and `test/app/users/user_test.exs`. End-to-end tests
that span several features belong at the project root; integration tests
covering several modules can live in a dedicated directory.

## Applying these boundaries

Apply these boundaries to the requested change, not as permission for a layout
migration. Follow existing patterns, and notice the patterns the code already
implies. Surface existing structural problems and obtain operator approval
before broad moves, dependency changes, or new boundary-enforcement tooling.
Preserve framework discovery, route mapping, and repository test/documentation
rules; colocation does not override them.
