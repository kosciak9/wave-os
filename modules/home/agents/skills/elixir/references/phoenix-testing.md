# Phoenix LiveView Testing

Apply this guidance when the repository permits test changes and LiveView tests
are the appropriate surface. Follow the actual project layout, fixture policy,
checks, and isolation strategy rather than importing another application's
setup. Protect meaningful user paths and domain behavior, not implementation
trivia.

## Exercise the markup users interact with

Prefer mounting a routable view with `live/2`, then using `element/3` and
`form/3` with `render_click`, `render_change`, and `render_submit`. These
helpers check the rendered control/form contract and catch wiring errors that
direct event dispatch can miss. Use direct dispatch only for a deliberately
lower-level server-event test, not as proof that the UI affords the action.

> ```elixir
> {:ok, view, _html} = live(conn, "/entries/new")
> view |> form("#entry-form", %{entry: %{title: "Sample"}}) |> render_submit()
> assert has_element?(view, "#saved-entry", "Sample")
> ```
>
> This illustrative route/form must be replaced by the application's real
> contract. Avoid asserting `html =~ "Sample"` when the text could merely be the
> unchanged input value rather than a saved result.

Scope assertions to the meaningful result/error area. Prefer semantic controls,
visible text, unique IDs, or established stable attributes over styling classes
and exact wrapper trees. Select one intended target; do not rely on ambiguous
substring matches. Harmless CSS/layout changes should not break behavior tests.

## Select the correct surface

- Forms: exercise validation and submission through actual fields. Assert error
  location, retained input, and the visible/persisted outcome, not just that an
  event returned HTML.
- Navigation: click the rendered link/control. Use `assert_patch` or redirect
  assertions when URL state is part of the contract; use `follow_redirect` when
  the destination matters and match its LiveView versus HTTP return shape.
- Components: `render_component` or HEEx with `rendered_to_string` can validate
  static output. Interactive LiveComponents need their parent LiveView to
  exercise mounting, event targeting, and updates.
- Async work: use `render_async` for supported LiveView async tasks instead of
  sleeping. Other jobs/messages need their own established deterministic
  synchronization. Do not assume it awaits every application process.
- Uploads: use `file_input` and `render_upload` for the supported server-side
  flow, then submit and verify the saved outcome. Check cancellation and failure
  where relevant. External uploader metadata is not proof of browser/provider
  integration; consult the installed helper contract before mixing preflight and
  completion on the same simulated upload.
- Hooks: `render_hook` exercises the server event contract, not the hook's
  browser JavaScript. Use real browser validation for client hooks, observers,
  focus, layout, and direct-to-provider upload behavior when those matter.

## Keep confidence high and interference low

Use a realistic critical path with intermediate assertions that localize
failure. Avoid duplicate tests that add no distinct confidence. Choose
fixture/action setup according to what is being tested; do not mandate bypass
seeds globally.

Use concurrency only when resources are isolated. Tests mutating application
environment, shared processes, caches, or external storage need deliberate
serialization/isolation and cleanup. Never disable framework warnings or checks
to accommodate broken markup. Run the focused path and the project's required
checks; compiling application modules alone does not execute an `.exs` test.
