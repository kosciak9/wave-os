---
name: work-delegation
description:
  "How to split work across subagents (Agent tool). Use before launching any
  subagent or when a task can be parallelised."
when_to_use:
  "'podziel na zadania', 'równolegle', 'odpal agentów', audits or research
  across many files/modules."
---

# Work Delegation

Unlike a human engineer, you have a significant advantage in terms of
coordination and communication. You can spawn subagents, in parallel, and
communicate with them when they finish. Use their batches of work to speed up
executing the task significantly.

If delegation is unavailable, work directly.

- Give each subagent one cohesive task with paths, constraints, and expected
  checks.
- Parallelize assignments only when they cannot conflict.
- Do not ask multiple agents to modify the same files concurrently.
- Make sure subagents are aware when working in parallel - so they don't e.g.
  reformat others work or run linter on incomplete files.
- Choose agents by competence and the assignment's scope, not by a required
  agent name.

  > Example: assign larger cohesive implementation work to a general-purpose
  > implementation agent and read-only research to a read-only exploration agent
  > when those roles are available and suited to the work.

- Keep responsibility for integration, review, and final verification.
- Review the resulting diff rather than trusting a completion claim alone. For
  research assignments, review the evidence and unresolved uncertainties.
- Optimize work for parallelization - pick batches that allow multiple agents to
  work concurrently, where possible.
- Try to get batches of work in between interacting with the user, to have
  longest possible streaks of autonomous work.
