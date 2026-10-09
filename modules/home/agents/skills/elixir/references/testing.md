# Elixir Testing Reference

> **Ash projects**: Use `DataCase` with `Ash.Test` helpers; test actions via
> domain code interfaces, not direct `Repo` calls. See [Ash](ash.md).

Quick reference for Elixir testing patterns. Apply it only where the repository
permits test changes; follow its existing case templates, fixtures, and
isolation strategy. For LiveView behavior tests also see
[LiveView testing](phoenix-testing.md).

## Iron Laws — Never Violate These

1. **ASYNC BY DEFAULT** — Use `async: true` unless tests modify global state
2. **SANDBOX ISOLATION** — All database tests use Ecto.Adapters.SQL.Sandbox
3. **MOCK ONLY AT BOUNDARIES** — Never mock database, internal modules, or
   stdlib
4. **BEHAVIOURS AS CONTRACTS** — All mocks must implement a defined `@callback`
   behaviour
5. **BUILD BY DEFAULT** — Use `build/2` in factories; `insert/2` only when DB
   needed
6. **NO PROCESS.SLEEP** — Use `assert_receive` with timeout for async operations
7. **VERIFY_ON_EXIT!** — Always call in Mox tests setup
8. **FACTORIES MATCH SCHEMA REQUIRED FIELDS** — Factory definitions must include
   all fields that have `validate_required` in the schema changeset. Missing
   fields cause cascading test failures

## Quick Decisions

### Which Test Case?

| Testing        | Use                                                     |
| -------------- | ------------------------------------------------------- |
| Controller/API | `use MyAppWeb.ConnCase`                                 |
| Context/Schema | `use MyApp.DataCase`                                    |
| LiveView       | `use MyAppWeb.ConnCase` + `import Phoenix.LiveViewTest` |
| Pure logic     | `use ExUnit.Case, async: true`                          |

### When to use async: true?

- ✅ Pure functions, no shared state
- ✅ Database tests with Sandbox (PostgreSQL)
- ❌ Tests modifying `Application.put_env`
- ❌ Tests using Mox global mode

### Mock or not?

- ✅ Mock: External APIs, email services, file storage
- ❌ Don't mock: Database, internal modules, stdlib

### build() or insert()?

- Use `build()` by default for speed
- Use `insert()` only when you need DB ID, constraints, or persisted
  associations

## Quick Patterns

```elixir
# Setup chain
setup [:create_user, :authenticate]

# Pattern matching assertion
assert {:ok, %User{name: name}} = create_user(attrs)

# Async message assertion
assert_receive {:user_created, _}, 5000

# Mox setup
setup :verify_on_exit!
expect(MockAPI, :call, fn _ -> {:ok, "data"} end)

# LiveView async
html = render_async(view)  # MUST call for assign_async
```

## Common Anti-patterns

| Wrong                                 | Right                             |
| ------------------------------------- | --------------------------------- |
| `Process.sleep(100)`                  | `assert_receive {:done, _}, 5000` |
| `insert(:user)` in factory            | `build(:user)` in factory         |
| `async: true` with `set_mox_global()` | `async: false`                    |
| Mock internal modules                 | Test through public API           |

## References

Load only the relevant detail:

- [testing-exunit](testing-exunit.md) - Setup, assertions, tags
- [testing-mox](testing-mox.md) - Behaviours, expect/stub, async
- [testing-liveview](testing-liveview.md) - Forms, async, uploads
- [testing-factories](testing-factories.md) - ExMachina, sequences, traits
