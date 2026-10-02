---
name: experimental-discovery
description: >-
  Explore genuinely new or poorly understood territory through experiments
  across substantially different approaches. Use for explicitly requested
  exploratory R&D, core uncertainty that code and documentation cannot resolve,
  or repeated ineffective fixes that call the underlying model into question.
  Not for routine implementation, API lookup, or every focused trial.
---

# Experimental Discovery

## When to use

Discovery is relatively rare in ordinary work, not the default response to
uncertainty. Use it when the user requests exploration beyond the local optimum,
when a core uncertainty requires comparing approaches rather than inspecting
code or documentation, or when repeated ineffective fixes suggest questioning
the underlying model. A generic request to "research" is not enough.

Planning, building, and discovery are composable intentions, not mutually
exclusive modes or mandatory phases. Planning can expose a need for exploration
and resume with its findings; building can provide the apparatus for it. A
focused experiment can also check a known implementation without broad
discovery.

If exploration would materially change the task, suggest it with a rationale and
bounded scope rather than silently turning routine work into open-ended R&D.
Choose breadth, cost, and duration compatible with the user's agreement; do not
ask again for every experiment within that authorized scope.

> Example: repeated local fixes fail for different reasons. Propose a bounded
> comparison of alternative representations to test the underlying model.
>
> Counterexample: the user asks to research an API option. Look up the existing
> contract and implementation; do not launch an architectural investigation.

## Begin broadly across problems and solutions

In early discovery, treat the problem statement as provisional: the stated
problem may be incomplete or framed around a symptom. Do not assume the question
is fixed and that research means comparing only solutions to it. Reconnoiter
broadly across existing solutions, how others frame similar problems,
neighboring problems and fields, relevant constraints, alternative goals, and
explanations for symptoms or underlying causes. Explicitly seek web and
literature sources, implementations, prior attempts, and different framings—not
just approaches that endorse the initial framing.

Start with broad, parallel reconnaissance batches where useful, then bring the
evidence into meaningful dialogue with the operator: discuss what it suggests,
which problem or goal might need reframing, and what remains uncertain. Continue
with another broad or narrower batch as needed. Build enough shared context for
several conversational turns; do not make research a separate round for every
question. Let problem definitions and targeted hypotheses emerge from findings.
A precise hypothesis is not a prerequisite for the first reconnaissance; later
significant targeted experiments still follow the experiment protocol below.

Keep breadth within the agreed resource and action budget. Researching adjacent
possibilities does not authorize implementation beyond the agreed scope.

> Example: if tools seem to be chosen poorly, investigate whether the issue is
> tool selection—or instead representation, information, responsibility, or
> success criteria. Those may be symptoms of a deeper mismatch.
>
> Counterexample: accept the initial framing as settled, then search only for
> solutions that endorse it.

Your job is to reduce uncertainty, not to make the first plausible solution work
at any cost. Use experiments to discover how a goal can be achieved, which
explanation fits the evidence, and where an approach reaches its limits.

Explore multiple promising regions of the solution space rather than climbing
only the nearest hill. Do not mistake improvements within one approach for
evidence that it is the best direction. Compare substantially different
approaches when that comparison is informative before committing to local
optimization; the aim is to find promising directions across the space, not to
claim proof of a global optimum. Do not invent alternatives merely to satisfy a
quota.

Code, prototypes, benchmarks, models, and subagents are research instruments. A
failed experiment can be a valuable result. Before turning a failure into a
patch, ask what it teaches about the problem.

> Example: two architectures could satisfy the goal, but the available code and
> documentation do not establish which one is viable. Design experiments that
> distinguish their capabilities and limitations.
>
> Example: one prototype improves after several patches. Test a substantially
> different architecture before spending the next iteration tuning that
> prototype; a better region may lie outside its design.
>
> Counterexample: keep patching the first prototype until it passes, without
> checking whether its underlying approach is sound.

## Choose the next experiment

Regularly ask: "What do we most need to understand, and which experiment would
change our understanding the most?"

Prefer experiments that:

- Distinguish competing explanations.
- Test an important assumption.
- Could falsify the currently preferred hypothesis.
- Explore a substantially different direction or reveal an approach's limits.

Do not choose work merely because it is the natural continuation of the previous
experiment. A small improvement to one solution can be less valuable than
finding out whether it is the right direction at all. Use information gain as a
judgment criterion, not a requirement to calculate a numerical score for every
experiment.

> Example: instead of repeating a tenth similar passing case, test a case that
> distinguishes two possible explanations for the improvement.
>
> Counterexample: keep tuning the same prototype because its score is improving,
> even though a major architectural assumption remains untested.

## Keep hypotheses alive and seek counterexamples

State important hypotheses so they can be challenged or falsified. Keep
supporting and contrary evidence, alternative explanations, and the results that
could distinguish them up to date as the research evolves.

Actively search the web for diverse hypotheses and substantially different
approaches; do not rely only on ideas generated from the current code or your
own reasoning. Look for opposing explanations, relevant research,
implementations, and lessons from adjacent domains, not just confirmation of the
preferred approach. Turn useful findings into testable hypotheses and keep
source pointers. An external claim is a candidate to investigate, not proof that
it applies to this system.

> Example: when a small model fails, look for work on representation,
> constrained action spaces, and runtime limitations as well as model quality,
> then design trials that distinguish those explanations.
>
> Counterexample: search only for examples endorsing the current architecture
> and treat their existence as evidence that it is correct.

After a result supports a hypothesis, look for the case most likely to break it
rather than merely repeating similar passing cases. Do not force a conclusion
when the evidence remains ambiguous.

> Example: "If checkpoints after screen transitions limit autonomy, removing
> them should lengthen local runs without reducing correctness." Test both a
> longer run and a case where the executor might accidentally start a new task.
>
> Counterexample: after three successful scenarios, conclude that checkpoints
> are unnecessary in every case.

Hypotheses may be open, supported, or rejected. Their status does not replace
evidence or establish a universal conclusion. Scale the amount of hypothesis
tracking to the research question rather than requiring a fixed number of
hypotheses or a formal ledger for every trial.

## Design the experiment before running it

Before a significant experiment, establish:

- **Question and hypothesis**: what the experiment should resolve.
- **Alternative explanations**: what else could cause the observed effect.
- **Expected observations**: which results would support the hypothesis and
  which would weaken or falsify it.
- **Variables and confounders**: what changes, what stays fixed, and what could
  distort the interpretation.
- **Evidence to preserve**: what will make the result checkable later.

> Example: to determine whether an improvement comes from the model or the
> contract, compare models under the same contract instead of changing both at
> once.
>
> Counterexample: build a prototype, obtain a score of 27/30, and only then ask
> what the result actually demonstrates.

Do not require an academic protocol for every trial. Scale preparation to
uncertainty and the cost of a mistaken conclusion; a simple trial may need only
a one-sentence description.

## Treat failure as a result

For failures relevant to the research question:

- Preserve important evidence before changing the system so a fix does not erase
  the only trace of what happened.
- Separate observations from interpretations.
- Determine whether the failure suggests a local bug, a faulty assumption,
  missing information, or a limitation of the approach.
- Decide whether a fix, a reproduction attempt, or an experiment that
  distinguishes possible causes would teach us more next.

> Example: an executor stops after a screen transition. Preserve the trajectory
> and investigate whether it lacked information, lost the goal, or could not
> execute a known action instead of immediately adding a checkpoint.
>
> Counterexample: add a heuristic for every new failure until the benchmark
> passes without checking whether the failures reveal the same underlying
> architectural problem.

Look for systemic understanding, not a system that works in 100% of cases at any
cost. A failed case can be a useful outcome if it reveals a boundary or rules
out an explanation.

Do not turn obvious incidental mistakes into research projects. Fix them and
continue when they do not bear on the research question.

> Example: a typo in an experimental script prevents it from starting. Correct
> the typo and rerun the intended experiment; it says nothing about whether the
> architecture under investigation is viable.

## Distinguish competing explanations

When several causes fit the same result, design a trial that distinguishes them
instead of choosing the most intuitive explanation. Select methods that answer
the question:

- **Control or baseline**: compare against a reference condition.
- **Ablation**: remove one element to test its contribution.
- **Frozen replay**: reuse the same inputs or a recorded trajectory to compare
  conditions without changing the underlying cases.
- **Oracle**: substitute a controlled, known-correct decision for the component
  under investigation.

> Example: the model fails, but a manually supplied correct decision lets the
> task succeed with the same representation and runtime. This narrows the
> investigation to the model or its decision process; it does not yet establish
> which part caused the failure.
>
> Counterexample: change the prompt, model, and runtime together, then attribute
> the improvement to the larger model.

Do not require every method in every experiment. Choose the simplest trial that
can actually distinguish the important explanations.

## Explore boundaries before choosing a compromise

On an important design axis, test substantially different variants before
settling on a hybrid merely because it sounds reasonable. Choose variants that
reveal different capabilities and limitations.

A variant does not have to be practical for production to be useful as an
experiment. Observe where it works, where it fails, and what it needs to
continue. Build the compromise from those findings rather than assuming that the
middle is best.

> Example: compare a large model performing almost the entire task with a local
> executor performing almost the entire task. Establish each approach's limits
> before designing the division of responsibility.
>
> Counterexample: build a hybrid immediately, then interpret every failure only
> as a configuration problem within that hybrid.

Do not require absolute extremes on every axis. Variants should be different
enough to teach us something important while remaining within safety boundaries
and the experiment's budget.

## Research broadly in parallel

Actively use parallelism to expand the evidence gathered in each research round.
When several important questions can be investigated independently, default to a
broad parallel batch. Do not run experiments sequentially merely because the
first one has already started.

Look for other valuable work that can run in parallel: literature searches,
attempts to falsify a hypothesis, comparisons of variants, baseline
construction, and analysis of earlier failures. A large batch is useful when
each path has a clear contribution to understanding and the results can be
compared meaningfully.

- Give each experimental path a question, hypothesis where relevant, scope,
  variable under investigation, expected evidence, and a way to check its
  result.
- Prefer paths that investigate different hypotheses, regions of the solution
  space, or independent controls. Repetitions are also valuable when they test
  variance or reproducibility rather than merely repeat similar results.
- Prevent cross-contamination through shared code, data, outputs, or runtime
  state. Isolate experimental resources when needed.
- Limit concurrency for real dependencies, contamination risks, or resource
  constraints, not out of habit.
- Compare the evidence, investigate disagreements, and update the hypotheses
  after the batch. Do not simply choose the most polished report.

> Example: in one batch, investigate a strongly local executor, a large-model
> baseline, an oracle, and alternative approaches found in the literature. Each
> path addresses a different question, and their combined evidence is more
> useful than tuning one prototype sequentially.
>
> Counterexample: have five agents modify the same prototype at once, leaving it
> unclear which change caused the improvement.

Parallelism is primarily between the research paths. Do not require the
coordinator to keep working while subagents run; the batch may finish before
synthesis begins.

## Code is research apparatus

Research apparatus must make results interpretable: know what ran, which
boundaries were real or substituted, and what the observations demonstrate.
Preserve important evidence before changing or discarding a variant. Follow the
environment's safety rules, protecting other people's work, secrets, external
resources, and irreversible operations. An encouraging result is not a
production commitment or permission to deploy.

## Start with deep qualitative understanding

The first priority is always thorough qualitative understanding. Inspect how the
system behaves, what it observes, which decisions it makes, and where or why it
fails. Existing systems, recorded traces, or controlled trials may suffice;
build a prototype only when needed to expose the mechanism. Do not start by
building a large benchmark or optimizing an aggregate score.

Choose representative and challenging cases that expose the mechanism. Preserve
inputs, intermediate states, decisions, outputs, and failure trajectories at the
level needed to understand what actually happened. Instrumentation should make
the experiment inspectable, not turn it into a production observability project.

> Example: inspect a recorded trajectory across one demanding workflow to
> distinguish missing information, poor decisions, and runtime limitations. If
> the trace lacks decisive evidence, add a controlled trial or a small runner.
>
> Counterexample: build a large evaluation suite, obtain a pass rate, and only
> then discover that its outputs do not explain how the system failed.

Once the mechanism and important failure classes are understood, use repeated
trials, controls, quantitative measurements, and larger representative
benchmarks to answer the remaining questions. Measure the outcome relevant to
the hypothesis rather than a convenient proxy, and interpret scores together
with the failures and limits of the tested cases.

> Example: a local model responds faster, but the full task takes just as long
> because it needs more observations and controller turns. Model latency alone
> does not establish an improvement in the workflow.

## Adapt the direction as evidence changes

Do not lock research into rigid broad or narrow modes. Adjust its breadth as the
evidence develops:

- Broaden when competing explanations remain plausible or a counterexample
  challenges a fundamental assumption.
- Narrow when independent results point to the same mechanism.
- Stop paths that no longer distinguish important explanations, repeat what is
  already known, or have been undermined by the evidence.
- Do not treat existing code or effort already invested as a reason to continue.

> Example: several experiments point to a representation problem, so focus on
> that mechanism. If a new case shows that explanation is insufficient, reopen
> the alternatives.
>
> Counterexample: keep tuning a chosen approach merely because a large amount of
> code has already been written.

Regularly ask: "If I knew the current results but had not written this code yet,
would I still start this work?" Let the answer guide the next experiment rather
than defending the current implementation.

## Synthesize knowledge and recognize convergence

After a substantial research batch, update the working model of the problem:

- **What we know**: observations supported by evidence.
- **What we suspect**: interpretations and their limitations.
- **What we ruled out**: hypotheses undermined within the tested scope.
- **What remains unknown**: unresolved questions.
- **What to investigate next**: experiments with the highest expected
  information gain.

This does not require a full user-facing report after every batch. Keep the
model current instead of accumulating unrelated TODOs.

Research has converged enough to choose a direction when the important
assumptions have evidence, alternatives can be compared meaningfully, and new
trials mainly reveal already understood mechanisms. Convergence means
understanding enough to choose deliberately, not achieving a perfect pass rate.

> Example: we can distinguish limitations of the representation from limitations
> of the model's decisions. We can choose an architecture even though not every
> case works yet.
>
> Counterexample: declare research complete merely because the latest prototype
> passes every prepared scenario.

Choosing a direction does not automatically authorize production implementation
or deployment. A new counterexample can reopen the research.
