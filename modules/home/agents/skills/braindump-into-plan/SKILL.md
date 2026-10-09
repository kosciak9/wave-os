---
name: braindump-into-plan
description:
  "Turns a rough idea into agreed requirements and a plan before implementation.
  Use when the user wants to plan, redesign, rebuild or migrate something, or
  shares a brain dump or RFC."
when_to_use:
  "'zaplanujmy przebudowę X', 'chcę przenieść X do Y', 'mam pomysł', 'jak byś to
  zrobił', any non-trivial change whose scope is not yet agreed."
---

# Braindump into Plan

## When to use

Use when rough intent or consequential choices need clarification into an
actionable direction. Planning usually accompanies ordinary changes, but an
obvious fix needs no ceremonial planning session. Scale the conversation and
plan to the actual decisions.

Planning, building, and discovery are composable intentions, not exclusive modes
or mandated phases. Planning may reveal a core uncertainty that code and
documentation cannot resolve; propose bounded experimental exploration when
needed, then resume with its findings. Routine fact gathering is not broad
discovery, and sufficiently clear work can proceed without a separate planning
phase when implementation is authorized.

> Example: clarify a feature's scope, investigate an uncertain design assumption
> within agreed bounds, and use the results to refine the implementation steps.
>
> Counterexample: require a brainstorming session before correcting an obvious
> typo whose intended behavior is already clear.

Turn rough ideas, RFCs, and brain dumps into a living, code-oriented plan.
Clarify the scope, outline a coherent target state, reconcile it with the
existing system, and make decisions explicit.

## Interaction Loop

1. **Understand the intent — conversation only**: do not use tools in the first
   turn except to load instruction skills. This exception does not allow
   repository, documentation, or environment inspection. Restate the user's goal
   in your own words, step by step, and surface initial observations and
   questions. Continue with short, tool-free exchanges for as long as needed to
   understand the intent, with the same instruction loading exception throughout
   conversational blocks.

   - Actively engage with the user to build a shared understanding of the goal.
     Keep exchanges short and focused so clarification progresses quickly.

     > Example: when working from a voice transcript, restate the requested
     > changes and flag ambiguous wording instead of silently choosing an
     > interpretation.

   - Do not interrupt this conversational block to inspect the repository.

     > Example: clarify whether the user means shared skills or shared agent
     > definitions before investigating how either is currently installed.

2. **Research ahead — a broad research block**: once the intent is sufficiently
   clear, inspect the repository and primary documentation in depth. Include
   closely related context beyond the agreed scope of changes when it can inform
   upcoming decisions. Collect relevant code snippets, trace dependencies, and
   identify constraints so the next conversation can progress without repeated
   research pauses. Use research subagents when available and useful.

   > Example: when extracting shared skills, inspect their sources, module
   > imports, provisioning, affected hosts, and harness discovery behavior
   > together rather than investigating each area only after a separate
   > question.
   - In the first research block, look slightly beyond the agreed change scope
     to anticipate likely follow-up questions. Researching an area does not add
     it to the plan or authorize changing it.

     > Example: when moving skills, also check duplicate discovery,
     > configuration precedence, and related commands so these can be discussed
     > without another pause.

   - Keep this expansion relevant and bounded.

     > Counterexample: do not analyze the entire plugin system or design a
     > marketplace unless it directly affects the requested change.

3. **Discuss findings — an interactive conversation block**: return with a
   concise summary of decision-relevant findings, then work through the choices
   in short exchanges using the context already collected. When unresolved
   decisions need the user's input, ask a focused batch of questions; do not
   insert a research block after every answer. Present the alternatives and
   explain why any were ruled out.

   > Example: use the same research batch to discuss installation scope,
   > ownership, and migration behavior over several conversational turns.
   - Start another research block only when the discussion moves beyond the
     context already gathered or reveals a significant knowledge gap.

     > Example: investigate a newly requested harness before claiming it
     > supports the chosen setup.

4. **Maintain the living plan**: keep the agreed requirements, decisions, open
   questions, and a concise list of implementation steps up to date as the
   conversation evolves.

Agents cannot reliably estimate elapsed completion time. Do not estimate
minutes, hours, or days, provide ETAs, promise completion dates, or compute
pseudo-schedules. Describe scope, dependencies, uncertainty, and validation
instead; qualitative scope groupings are fine. If asked for duration, explain
that a reliable estimate requires evidence rather than inventing one. Actual
measured durations and user-set deadlines or budgets may be recorded, but are
not completion estimates.

### Interaction rhythm

> Good: several conversational exchanges, one broad research block, then several
> more conversational exchanges informed by its findings.

> Bad: a question, a long research pause, another question, and another long
> research pause for each decision.

## Output Format

Adapt the response to the current phase. Keep conversational replies concise; do
not repeat a full plan or use a fixed set of headings in every turn.

- **Initial conversation**: restate the goal in short, ordered points, surface
  initial observations, and ask about the most important ambiguity when needed.

  > Example: "You want to share skills across harnesses without changing their
  > contents. Should they be available globally?"

- **Follow-up conversation**: respond to the user's input, explain how it
  affects the plan, and ask a focused batch of questions if unresolved decisions
  need the user's input. Do not repeat settled context or the entire worklist.

  > Example: "Global installation is agreed. Should the browser skill move as
  > well?"

- **Return from research**: summarize decision-relevant findings, give a
  recommendation with its main trade-off, and ask a focused batch of questions
  if unresolved decisions need the user's input. Keep supporting detail
  available for follow-up rather than presenting the entire research report.

  > Example: "Two harnesses discover the shared global directory; the others
  > need integration. I recommend one source of skill content. Should
  > integrations be included now or later?"

- **Plan closure or an explicit summary request**: provide a fuller summary of
  the objective, scope, constraints, agreed decisions, implementation steps,
  verification criteria, and any remaining open items.

  > Example: "The plan is agreed, with no open decisions. Implementation has not
  > started."

## Additional information

### Planning and implementation boundary

When the user requests planning only, inspect code and research as needed, but
do not modify implementation files or perform operational changes. Planning
alongside authorized implementation does not suspend that authorization; stay
within its agreed scope.

> Example: inspect the installation module to plan a migration, but leave the
> module unchanged during planning.

Agreement on a requirement or approach is not permission to implement it. When
the user explicitly requests implementation, execute the agreed scope and
continue refining the plan as needed. Do not refuse merely because this skill
was used earlier. You can recommend jumping to implementation when you believe
the plan is fully fleshed out.

> Example: "The plan is complete; I recommend moving to implementation." If the
> user then says "Implement it," execute the agreed scope.

If the user explicitly asks to record or update the plan in a file, edit only
that planning artifact, subject to repository rules.

### Do not overwhelm the user

Usually, when working through a brain dump, there are a lot of things to
consider—how to turn a feature into an actual implementation, handle all use
cases properly, and make it fit with the existing code—or refactor that code to
accommodate the feature.

That is why you should usually refrain from proposing new features during this
process. Surface the relevant implementation considerations, but stay focused on
the user's request.

> Example: discuss discovery and migration for shared skills without proposing a
> new skill marketplace.
