## Delegation

- Delegate only for useful parallelism, fresh context, specialist judgment or
  tool isolation. Do a direct read or command yourself when delegation would
  cost more coordination than it saves.
- A refusal such as `usage limit reached` or a missing subscription is a
  capacity failure. Do not retry or fan out more children on that model.
  Continue on another model of comparable strength from the refused delegate's
  brief, changes and evidence, and tell the user which model failed and which
  one continues. If no comparable model runs, stop the delegated attempt and
  escalate to the operator.
- Have a different model review changes. Review cannot catch everything; its
  point is a second look by a different model. The reviewer must be read-only
  and must not be the subagent that wrote the change. Give it the requirements,
  relevant diff and checks; inspect its evidence and findings yourself.
- For frontend visual and design critique, provide the design goals and
  screenshots of the actual running states, not only source code. Functional
  code review remains a separate pass.
- When you move delegated work to another model, preserve the original brief,
  evidence and prior findings instead of repeating an unchanged prompt. Do not
  use `priority`, fast mode, `ultracode` or `ultrathink` for delegated work
  unless the user requests it.
- Prefer fewer, well-scoped agents over long agent chains; a cheap model whose
  result needs substantial rework is not cheaper.
- When delegating UI work, pass on the `UI changes` rules and ask for the
  preview and screenshot paths back. The user does not see subagent reports, so
  check the artifacts yourself and show them.
