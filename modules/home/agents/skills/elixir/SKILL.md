---
name: elixir
description:
  "Elixir coding rules. Use whenever you read or edit .ex/.exs files, including
  Ash, Phoenix and Ecto code."
when_to_use:
  "'moduł Elixir', Ash resources and actions, GenServer, Phoenix, LiveView,
  Ecto."
---

# Elixir

## Language core

Follow the project's supported runtime, Mix aliases, formatter, compilation,
test layout, and verification requirements. Existing checks and repository rules
take precedence over generic language conventions.

- Use pattern matching and function clauses to make valid input shapes visible.
  Keep guards simple and branches readable; prefer `case` or `with` when they
  express the actual error flow clearly.
- Preserve explicit success/error contracts. Use raising functions only where
  failure is intentionally exceptional; do not erase meaningful domain errors
  with broad rescue blocks or opaque fallback values.
- Elixir conditionals do not return early from a function. Use clauses or an
  explicit branching construct, not sequential `unless` expressions pretending
  to be guard returns.
- Keep pure transformations distinct from effectful orchestration. Put domain
  rules behind the established context/domain interface instead of scattering
  persistence decisions through callers.
- Use structs and typespecs for meaningful contracts where appropriate. At
  external boundaries, parse and validate data; do not create atoms from
  unbounded user input.
- Add a process only for a real ownership, concurrency, or lifecycle need. Keep
  supervised dependencies ordered intentionally, message contracts explicit, and
  callbacks lightweight. Do not use sleeps as synchronization.
- Make task failure, retry, idempotency, and shared-state behavior explicit. Do
  not assume spawned work shares a database transaction or that process-local
  state is durable.
- Distinguish database atomicity from external side effects. Keep credentials
  out of persisted metadata, committed files, logs, and rendered output.

> Prefer clauses or `with` to propagate `{:error, reason}` deliberately. Avoid
> `unless valid?, do: {:error, :invalid}` followed by an unconditional write:
> the conditional did not exit the function.

Keep state ownership, side effects, and dependency direction understandable. Do
not replace ordinary functions with macros or a new framework merely to reduce a
few lines of local code.

## Selective framework references

Loading this skill loads only this entrypoint. Confirm frameworks from Mix
dependencies and the actual modules. Read only the applicable framework
entrypoint, then its task-specific detail; do not preload the entire index.

- Resource/action modeling and authorization: [Ash](references/ash.md).
- Web boundaries, LiveView, HEEx, UI and interaction validation:
  [Phoenix](references/phoenix.md).

If both are present, load each only for the part of the task that uses it. For
other libraries, retain the language core and consult the installed version's
documentation rather than imposing these frameworks.
