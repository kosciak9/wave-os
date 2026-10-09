---
name: build-orchestration
description:
  "Runs larger multi-step implementations in tracked batches. Use when an agreed
  change touches many files/modules or needs several stages."
when_to_use:
  "'zaimplementuj cały plan', 'przebuduj moduł', migrations, multi-PR or
  multi-stage work. Not for small fixes."
---

# Build Orchestration

## When to use

Use for larger tasks whose dependencies and integration benefit from organized
batches, not every small fix. Building can deliver a production change, a
prototype of a chosen idea, or research apparatus; it does not imply production
readiness or deployment permission.

Planning, building, and discovery are composable intentions, not exclusive modes
or mandatory phases. Continue planning as decisions arise during execution. A
focused trial may verify a known implementation without broad exploration; if
core uncertainty requires substantially different approaches, propose bounded
exploration rather than silently expanding the build into open-ended R&D.

> Example: coordinate a minimal end-to-end app integration from a sufficiently
> clear approach, even though its purpose is to examine feasibility rather than
> ship production code.
>
> Counterexample: require orchestration and a separate formal planning phase for
> a straightforward one-line fix.

Coordinate multi-stage implementation from an agreed goal and scope through
execution, integration, and verification. Actively organize the work to take
advantage of parallel execution: identify independent tasks, make dependencies
explicit, and prepare useful batches that let agents work concurrently.

Keep ownership of the overall result, whether the work is delegated or performed
directly. Optimize for faster delivery of a coherent, verified result—not for
the number of agents running at once.

> Example: once the shared interfaces are agreed, assign independent components
> to separate agents and integrate their results once the batch completes.
>
> Counterexample: split tightly coupled changes across several agents before
> their shared assumptions are settled, creating conflicts and rework instead of
> speeding up delivery.

## Starting point

Begin when the user has requested implementation and the goal and scope are
sufficiently clear, with an approach clear enough to start. A formal plan is not
required. Break the agreed work into actionable steps without silently expanding
its scope.

> Example: the user asks to extract shared skills into a separate module.
> Inspect the current setup and organize the necessary moves, imports, and
> verification without requiring a separate planning session.
>
> Counterexample: treat approval of an approach during brainstorming as
> permission to start implementing it.

## Prepare the first batch

Turn the agreed scope into a structure that supports parallel work. This is not
another brainstorming session or a detailed plan for the entire project.

1. **Gather assignment context**: inspect the entry points, affected components,
   conventions, and available verification methods needed to prepare actionable
   assignments.

2. **Map dependencies and shared decisions**: identify what can proceed
   independently and what needs an agreed interface or the result of another
   task first.

3. **Prepare an executable batch**: make the first batch precise enough that
   agents do not have to guess the goal again. Refine later batches using the
   results of completed work.

> Example: agree on the data exchange format before implementing a producer and
> consumer in parallel, then assign each side separately.
>
> Counterexample: ask both agents to "adapt to the other side" without settling
> their shared assumptions.

This step organizes execution order and dependencies.

## Execute in batches

Parallelism happens primarily between subagents. Do not assume the harness
allows the orchestrator to keep working while they run.

1. Prepare cohesive assignments for independent tasks.

2. Launch those assignments in parallel using the harness's available
   capabilities.

3. Wait for the results.

4. Review and integrate the changes, verify them, and address any problems.

5. Update progress and prepare the next batch based on the actual implementation
   state.

Do not require background work, individual result streaming, or starting
dependent tasks before the batch completes. Do not duplicate work already
assigned to a subagent. If parallel execution is unavailable, carry out the
tasks using the harness's supported execution model rather than pretending they
run concurrently.

> Example: launch two agents for independent components. Once their results are
> available, check that the components fit together and prepare the next batch
> from the actual implementation state.
>
> Counterexample: make execution depend on the orchestrator working alongside
> subagents when the harness blocks it until they finish.

## Integrate and verify

Review returned assignments and check that the results fit together and satisfy
the agreed goal: individually correct components can still form a broken whole.

Keep validation small and focused during iterations with the user so the
feedback loop stays fast. Run checks targeted at the changed behavior or
integration boundary, and leave broad, expensive validation for the end of the
work. Follow the project's validation rules; do not postpone a check that is
necessary to safely continue or avoid building on a faulty result.

If verification fails, prepare a specific correction or repair assignment and
verify the result again. Distinguish failures introduced by the change from
pre-existing repository or environment problems. Do not expand the scope to fix
unrelated problems without agreement.

> Example: during an iteration, check the interface between two changed
> components rather than rebuilding the entire project after every user answer.
> Run the broader project checks once the implementation is ready for final
> verification.
>
> Example: both components pass their local checks, but use different field
> names. Correct the mismatch and verify their combined behavior before building
> dependent work on top of them.
>
> Counterexample: treat agent completion reports as proof that the combined
> implementation works, or repeatedly run the full validation suite during small
> conversational iterations.

## Track progress

Use the harness's task list when available; otherwise keep a concise working
list. Track all work, whether delegated or performed directly.

- Record dependencies and blockers so it is clear which tasks can run next.
- Distinguish work returned by an agent from work reviewed, verified, and
  completed. Do not treat a completion report as proof that a task is done.
- Update progress after meaningful results, not after every tool call.
- Use the statuses supported by the harness rather than requiring a particular
  set of status names.

> Example: an agent delivers a component, but integration reveals an interface
> mismatch. Mark the task as needing correction rather than complete merely
> because the agent returned a result.
>
> Counterexample: mark every task complete upon receiving agent reports, before
> reviewing their changes.

## Continue or finish

Continue through successive batches independently within the agreed scope.
Return to the user when a material decision, a scope change, or help with a
blocker is needed. Do not stop after every batch merely to ask whether to
continue.

When the implementation is ready, run final validation and summarize the result,
checks performed, and remaining limitations. If something cannot be verified,
state that explicitly rather than presenting an unverified result as complete.

> Example: the next batch follows from the agreed scope, so start it without
> another permission question. If integration reveals two options with different
> user-visible consequences, return for a decision.
>
> Counterexample: ask for approval of every technical step, or claim full
> completion when final validation could not be performed.
