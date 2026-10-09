---
name: typescript
description:
  "TypeScript/TSX coding rules. Use whenever you read or edit .ts/.tsx files,
  including React components."
when_to_use: "'komponent React', 'popraw w TS', Next.js, Node, frontend code."
---

# TypeScript

## Language core

Follow the repository's compiler settings, runtime targets, package manager,
module conventions, and checks. Do not change strictness or install a preferred
stack as an incidental part of implementation.

- Model valid states explicitly. Prefer discriminated unions over combinations
  of optional properties and booleans that admit impossible states.
- Accept untrusted data as `unknown` and validate it at the boundary using the
  project's established validation mechanism. Types are erased at runtime;
  assertions do not validate network responses, URL parameters, or stored data.
- Prefer inference for local values and explicit contracts for exported
  boundaries. Use generated API types where available; do not maintain a second
  handwritten copy of the server schema.
- Narrow values before using them. Avoid `any`, non-null assertions, and casts
  that conceal a contract mismatch. Handle absence deliberately rather than
  letting `null`, `undefined`, and empty collections mean interchangeable
  things.
- Use generics to preserve a real relationship between inputs and outputs, not
  to make a one-purpose function appear universal.
- Keep transformations pure where practical. Avoid mutating shared inputs or
  disguising side effects in getters and mapping callbacks.
- Await promises whose outcome matters. Give intentionally detached work an
  explicit error owner; do not swallow rejections or pretend partial failure is
  success. Model cancellation, races, retries, and duplicate requests at the
  layer that owns the operation.
- Keep server secrets and privileged credentials out of browser bundles,
  serialized props, logs, and committed files. Frontend validation and
  visibility checks never replace server enforcement.

> Prefer `{ status: 'ready', data } | { status: 'failed', error }` to a value
> that can simultaneously say `ready: true` and contain an error with no data.
> Avoid `response as ExpectedResult` as a substitute for validating a response.

Keep feature-specific types and data access near their consumers. Reuse actual
project clients and adapters for transport, authentication, and error handling;
do not invent helper imports or duplicate generated schemas.

## Selective framework references

Loading this skill loads only this entrypoint. Identify the framework from
dependencies and implementation, not from the `.tsx` extension alone. Read only
the relevant entrypoint below, then only its task-specific references.

- React components, hooks, and rendering: [React](references/react.md).

For other frameworks, retain this language core and consult documentation for
the installed version instead of applying React-specific patterns.
