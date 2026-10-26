---
name: babysit-pr
description:
  Takes a pull request through CI and review to a mergeable state. It reads the
  findings, fixes the real ones, rebases onto the base, and keeps the PR
  current. Use when the user asks to monitor, watch, or babysit a PR. Watching
  requires T3 Code; everything else works without it.
when_to_use:
  "'pilnuj PR-a', 'doprowadź CI do zielonego', 'popraw uwagi z review', after
  filing a PR."
---

# Babysit PR

The job is to make the PR correct and current, not to narrate waiting. Works in
any repository: discover the checks and merge rules from the repository's
instructions and the base branch ruleset instead of assuming the defaults below.

## Watching

Never write your own polling loop, `sleep` loop, or background watcher script.

- **In T3 Code**: handle the existing checks, comments, and reviews first, then
  call `watch_pull_request` and end your turn. T3 Code wakes you when a check
  fails, the required checks pass, someone comments or reviews, or the branch
  conflicts. A wake is news, not a merge decision: verify the gate yourself.
- **Without that tool**: do the work that is already visible, then hand the
  thread back with the current state and what you are waiting for. Do not run a
  loop that burns the forge's rate limit.
- **Only the thread that owns the PR watches it.** A delegated child task never
  calls `watch_pull_request`; the parent owns the PR.
- **Unwatch when you hand off.** Call `unwatch_pull_request` before you stop for
  a question or a handoff. Merging or closing ends the watch on its own.
- When an event needs no action, end your turn without a message. Never post or
  say "still waiting".

## Reviews and CI

- Only act on checks and comments newer than the latest push. Verify every
  reported finding against the source before changing code; a bot's claim is a
  hint, not evidence.
- Fix real findings and real CI failures. Distinguish repository failures from
  infrastructure flakes, and say which it was.
- Check which bots are gating and which are advisory in the base branch's
  required checks. Wait for gating ones; do not hold a merge for advisory ones.
- Decline false positives with a written reason. Use the `leaving-pr-comments`
  skill for every comment posted on the user's behalf.
- Respond only to findings about this diff. Do not expand the review into code
  the PR does not touch.

## Keep the PR the size the goal needs

Review loops grow a PR one cheap-looking fix at a time. Fix real bugs in the
intended case and decline the rest with a reason, listing them as follow-ups:
unneeded tests, guards for cases that do not matter, extra compatibility
surfaces, or small performance costs. Prefer the change that deletes or narrows
code.

## Base branch

- Watch for the base branch moving. When the base branch requires an up-to-date
  branch, a stale PR blocks the merge even when CI is green on the old base.
- Rebase onto the current default branch, resolve conflicts according to the
  PR's intent, push with `--force-with-lease`, and wait for green again.
- If base commits that landed after the last green run touch this PR's files,
  recheck the behavior, not just the conflict markers.
- If another PR makes this one obsolete, stop and report it. Do not close the PR
  unless the user authorized closing.

## Stopping

Stop when the merge gate passes, then either merge (only when explicitly asked,
per `full-send`) or report readiness. Right before a merge, fetch, check the PR
again, and confirm it is not behind, dirty, or blocked.
