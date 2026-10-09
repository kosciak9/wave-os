---
name: agentic-coding-retro
description:
  Runs an adversarial retrospective over the user's past coding-agent sessions
  across harnesses and hosts, finds every signal that the agent setup did not
  work as intended, and then turns agreed problems into verified fixes to
  instructions, skills, and harness configuration.
disable-model-invocation: true
---

# Agentic coding retro

The goal is to find out, from evidence, where the user's agent setup (system
prompts, instruction files, skills, harness settings, subagents, repository
rules) fails them, and then fix the causes. It is a two-stage process: first
collect all problems without proposing fixes, then fix only what the user
prioritizes. The user decides what counts as a problem; the transcripts supply
the evidence.

## 1. Scope

Agree on the period (usually since the last change to the agent setup), the
harnesses, and the hosts. Find the setup change in the configuration
repository's history and use its timestamp as the cut-off. Include every host
the user works on; sessions stored on another machine are part of the evidence.

## 2. Collect the sessions

Locate each harness's session store and inspect its current format before
parsing it; formats change between versions, and one host may run an older
schema than another. Typical stores are per-project JSONL transcripts or a
SQLite database with session, message, and part tables. Open databases
read-only. For remote hosts, run the extraction there and transfer only the
condensed output rather than copying large databases.

Convert every session into a condensed, uniform transcript:

- Full human messages and full agent replies, with timestamps.
- Tool calls reduced to name, truncated input, and truncated output; keep error
  output longer.
- Skill loads marked explicitly, with the skill name.
- Subagent sessions folded into their parent as prompt plus final answer, with
  the subagent's prompt labelled as coming from the parent agent, not the user.
- Messages before the cut-off dropped; empty sessions dropped.

Also extract the intended behavior: read the sessions or documents where the
current setup was designed and write down what the user explicitly wanted and
rejected, with short quotes. Problems are measured against that intent.

## 3. Review in parallel

Split transcripts into size-balanced batches and give each batch to a reviewer
with one shared brief. The brief states the setup background, the transcript
format, and what to look for, adversarially and specifically:

- User corrections and frustration: repeated requests, "no", rephrasing,
  interrupts, the user doing the work, abandoned threads.
- Ignored instructions, unrequested scope, needless questions or missing ones,
  stopping short, success claimed without verification, confident claims later
  retracted.
- Skills that should have loaded but did not, loaded but were ignored, or caused
  ceremony; skills conflicting with each other or with repository rules.
- Communication: length, language, jargon, references the user cannot open,
  commands mixed between "for you" and "for me".
- Delegation: overspawning, unreadable subagent prompts, unverified subagent
  results.
- Workflow friction: worktree, commit, and push rules causing loops; heavy
  validation; collisions between parallel sessions.
- Differences between harnesses and models.

Each finding needs a concrete statement, a category, evidence (a short quote and
its timestamp), and a likely cause or "unclear". Each reviewer ends with
recurring patterns and counts.

## 4. Verify before reporting

Reviewer output is a lead, not a fact. Check the claims that would drive a fix:

- Separate real signals from artifacts of your own extraction (for example a
  renamed tool parameter that makes every skill load look empty).
- Count what can be counted directly from the stores: skill loads per harness
  and per skill, subagent types per day, sessions per host.
- Check deployment state on each host: stale agent definitions, plugins, or
  commands left outside configuration management; skills that never reached
  their target directory.
- Check claims about harness behavior against the installed version's source or
  documentation, not against memory or another reviewer's summary.

## 5. Report problems only

Present all problems first, without fixes. Rank by how fundamental they are:
broken foundations (skills not loading, configuration not deployed) before
behavioral patterns, behavioral patterns before isolated incidents. Group by
pattern, give counts, and keep one or two pieces of evidence per point. Contrast
harnesses where they fail in opposite directions. End with where the shipped
setup diverges from the intended behavior. Quote the user's frustration only as
much as the evidence needs.

Let the user respond point by point. They will accept some problems, dismiss
others, and calibrate the rest (for example how much proactivity they want).
Their answers define the fix list.

## 6. Fix with evidence

- Immediate hygiene first: remove stale files, fix deployment paths, enable
  settings the user asked for.
- Before changing instructions, find out how each harness assembles its system
  prompt and loads instruction files and skills: which files it reads, whether a
  custom agent prompt replaces built-in model-specific prompts, how skill
  descriptions are listed and whether they are truncated.
- When a cause is uncertain, run a controlled experiment instead of guessing:
  realistic prompts in the user's language, including verbatim first messages
  from real sessions; a baseline and variants; a control that isolates the
  changed factor; read-only tools and a scratch copy of a repository; results
  counted from machine-readable output.
- Keep fixes small and separately reviewable, one logical change per commit, and
  deliver them where the user reviews (for example a pull request).
- Instructions written for agents must stand on their own: no references to the
  retro, this session, or its evidence.
