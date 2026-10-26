---
name: full-send
description:
  Takes an agreed change all the way to a merged pull request without further
  input. It proves the change, reviews it with sol-loop, files the PR, babysits
  it through CI and review, and merges it. Use only when the user explicitly
  asks for it. Requires T3 Code.
when_to_use:
  "'full send', 'doprowadź do końca bez pytania', 'zrób i zmerguj', 'nie
  będziemy tego pilnować', hands-off delivery of a change to a merged PR."
---

# Full Send

Use this only when the user asked for "full send" in some clear way. If they did
not, work normally and stop before merging.

The user is not watching this thread. They will read the final message long
after you stop. You own the work from its current state to a merged PR.

This skill works in any repository, but only inside T3 Code. It states the gates
a PR must pass; you discover each repository's concrete conventions, commands,
and language in step 0 and follow those instead of any default mentioned here.

## Requires T3 Code

This skill depends on T3 Code tools and does not degrade to another harness.
Before you start, confirm that all of these are available: `link_pull_request`,
`watch_pull_request`, `unwatch_pull_request`, `orchestrator_capabilities`, and
`delegate_task` (used by `sol-loop`).

If any of them are missing, stop before editing anything and tell the user in
one short message that this skill needs T3 Code, naming what is missing. Do not
substitute a hand-rolled watcher, a polling loop, or a different reviewer, and
do not run a partial version of this workflow.

## What the request grants

- Commit, push, and rebase this task's branch, including `--force-with-lease`
  after a rebase of that branch only.
- Merge the PR once the merge gate below passes.
- Use the test method that gives direct proof without asking first: running the
  app or a dev server, browser automation, screenshots, visual checks. This
  replaces repo ask-first rules for testing only, not the rules about how to
  test.
- Treat the request as the explicit permission to commit and push that the
  repository instructions otherwise require.

## What it does not grant

- Production changes, deployments, activations, or deleting user data.
- Force-pushing any other branch, closing someone else's PR, or rewriting
  another task's work.
- Bypassing branch protection, required reviews, or `--admin` merges.
- Merging a change whose proof covers behavior you never actually ran and looked
  at.

## 0. Learn this repository's conventions

Do this before the first edit, and reuse the answers for the whole task.

- **Instructions.** Read the repository's `AGENTS.md`, `CLAUDE.md`, and any
  `CONTRIBUTING` file, plus nested ones for the directory you touch, and any
  global instructions. Repository rules win over the defaults in this skill.
- **Merge method.** Run
  `gh repo view --json mergeCommitAllowed,squashMergeAllowed,rebaseMergeAllowed,deleteBranchOnMerge`
  and read the base branch ruleset for allowed merge methods and required linear
  history. Confirm with recent history: `git log --first-parent --oneline -10`
  and whether merged PRs carry one commit or a merge commit. Never pick a method
  the repository has disabled.
- **Merge gate.** Read the base branch's protection or ruleset: required status
  checks, whether the branch must be up to date, required reviews, and required
  thread resolution.
- **Branch naming, commit titles, and PR language.** Take them from the
  repository instructions, then from recent merged PRs and the commit log. Match
  the language those PRs are written in, and the language the user writes in
  when that is unclear.
- **Checks.** Find the commands CI runs, from the CI config and the repository
  instructions, and run the same ones locally.

If the repository's instructions forbid something this skill assumes, such as
automatic commits or merging, follow the instructions: stop at that point and
hand off instead of overriding them.

## Steps

1. **Finish the change.** The smallest change that satisfies the request. Fix
   the case that happened, not every case that could. Do not work directly on
   the default branch: create a branch or a worktree first.
2. **Prove it.** Evidence you observed yourself in this session, for every edit
   in the diff. Reproduce the original failure, apply the fix, watch the same
   reproduction pass. Run the checks CI runs. For UI and runtime behavior, run
   the app and look at the change; green tests are not proof of the experience.
   When you cannot prove something, you do not have full confidence.
3. **Review it.** Run the `sol-loop` skill over the diff before filing. Rebase
   onto the latest default branch first.
4. **File the PR.** Open a real PR, not a draft. Title and description follow
   the conventions from step 0: lead with the problem the change solves, keep
   the body short, and say how you proved it. Do not restate the whole diff.
   Register the PR with `link_pull_request` immediately after creating it. Check
   the body and attachments for secrets and private details.
5. **Babysit it.** Follow the `babysit-pr` skill: fix real findings and CI
   failures, get proof for each fix before pushing, rebase when the base moves.
6. **Merge** when the merge gate passes, with the method and branch deletion
   behavior the repository uses. Do not pass `--delete-branch` against the
   repository's setting, and do not merge in a way the ruleset disallows.
7. **Report** the PR link, the merge commit, the proof, every decision you made
   without asking, and anything you left out.

Stay active from step 1 to step 7. Ending your turn while checks or reviews are
pending stops the work, because nobody will prompt you again. Use
`watch_pull_request` from `babysit-pr` so an event wakes you, and call
`unwatch_pull_request` before you hand the thread back.

## Merge gate

Full confidence means all of these hold on the latest commit:

- Your proof covers every change in the diff.
- Required checks are green.
- Each review finding is fixed, or dismissed with a written reason.
- No human review requests changes, and no required review is missing.
- The branch satisfies the base branch's freshness rule. When checks are strict
  or the branch is behind, rebase, push, and wait for green again.
- GitHub reports the PR mergeable, not dirty or blocked.

Merge through branch protection as configured. Never bypass it.

## Asking the user

Use your harness's question tool rather than a plain message, with the PR link,
the blocker, and options, your recommendation first, so the thread visibly waits
instead of looking finished. That is `question` in OpenCode, `AskUserQuestion`
in Claude Code, and `request_user_input` in Codex. Ask only when you cannot
continue: the change cannot be proven, the gate cannot pass for a reason you
cannot fix, the next step is outside the grant above, the repository's rules
forbid the remaining step, or the goal is ambiguous in a way that changes the
result.

Decide everything else yourself with a sensible default and list those decisions
in the report.
