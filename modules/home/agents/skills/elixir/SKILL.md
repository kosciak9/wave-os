---
name: elixir
description:
  "Elixir coding rules. Use whenever you read or edit .ex/.exs files, including
  Ash, Phoenix and Ecto code."
when_to_use:
  "'moduł Elixir', Ash resources and actions, GenServer, Phoenix, LiveView,
  Ecto, Oban jobs, ExUnit tests, Tidewave."
---

# Elixir

## Language core

Follow the project's supported runtime, Mix aliases, formatter, compilation,
test layout, and verification requirements. Existing checks and repository rules
take precedence over generic language conventions.

- Use pattern matching and function clauses to make valid input shapes visible.
  Keep guards simple and branches readable; prefer `case` or `with` when they
  express the actual error flow clearly. Use `with` for several dependent steps,
  not one; normalize errors in helpers instead of growing `else`. `%{}` also
  matches structs; use `is_non_struct_map/1` when the distinction matters.
- Preserve explicit success/error contracts. Use raising functions only where
  failure is intentionally exceptional; do not erase meaningful domain errors
  with broad rescue blocks, catch-all `_ ->` clauses, or opaque fallback values.
  Rescue specific exceptions around external code, never for control flow.
- Access required keys assertively (`map.key` or a pattern), keeping `map[:key]`
  for genuinely optional keys. Model mutually exclusive flags as one atom or
  `Ecto.Enum` field rather than several booleans.
- Elixir conditionals do not return early from a function. Use clauses or an
  explicit branching construct, not sequential `unless` expressions pretending
  to be guard returns.
- Keep pure transformations distinct from effectful orchestration. Put domain
  rules behind the established context/domain interface instead of scattering
  persistence decisions through callers.
- Use structs and typespecs for meaningful contracts where appropriate. At
  external boundaries, parse and validate data; do not create atoms from
  unbounded user input.
- Add a process only for a real ownership, concurrency, or lifecycle need, and
  start every long-lived process under a supervisor. Keep supervised
  dependencies ordered intentionally, message contracts explicit, and callbacks
  lightweight; move expensive initialization to `handle_continue/2`. Do not use
  sleeps as synchronization.
- Messages and closures copy what they reference: extract the needed fields
  before `spawn`, `Task`, `assign_async`, or a send instead of capturing a whole
  `conn`, socket, or struct. Process-local state such as the Gettext/CLDR locale
  does not follow spawned work; read it in the caller and pass it explicitly.
- Make task failure, retry, idempotency, and shared-state behavior explicit. Do
  not assume spawned work shares a database transaction or that process-local
  state is durable.
- Distinguish database atomicity from external side effects. Keep credentials
  out of persisted metadata, committed files, logs, and rendered output.
- Declare files read at compile time with `@external_resource`. Mix tasks run
  `app.config` and start only the applications they need, not `app.start`.

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

If both are present, load each only for the part of the task that uses it.

Topic references, each an entrypoint with its own detail index:

- Running app (eval, SQL, logs, schemas, docs) when Tidewave MCP is connected:
  [Tidewave](references/tidewave.md). Version-matched library docs:
  [HexDocs](references/hexdocs.md).
- LiveView mount, async data, streams, forms, uploads, JS interop, PubSub:
  [LiveView patterns](references/liveview.md).
- Background jobs: [Oban](references/oban.md).
- ExUnit, sandbox, Mox, factories, LiveViewTest:
  [Testing](references/testing.md).
- Authentication, authorization, input validation, headers, rate limiting:
  [Security](references/security.md).
- Ecto N+1 queries and preloads: [N+1](references/ecto-n1.md).
- Choosing and structuring processes (GenServer, Task, ETS, Registry,
  supervisors): [OTP](references/otp.md). Production memory, timeouts and
  crashes: [BEAM troubleshooting](references/beam-troubleshooting.md).
- Elixir 1.20 type-checker warnings: [Types](references/elixir-types.md).
- Writing Mix tasks: [Mix tasks](references/mix-tasks.md).

Parts of these topic references are adapted from phxagents
([NOTICE](NOTICE.md)); where they conflict with the language core, Ash, or
Phoenix guidance above, those take precedence. For other libraries, retain the
language core and consult the installed version's documentation rather than
imposing these frameworks.
