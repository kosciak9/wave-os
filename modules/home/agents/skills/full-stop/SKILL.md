---
name: full-stop
description:
  Takes an agreed change to a pull request that is ready for the user to merge,
  without merging it. Use only when the user explicitly asks for it. Requires T3
  Code.
when_to_use:
  "'full stop', 'doprowadź do gotowego PR-a', 'przygotuj do zmergowania, ale nie
  merguj'."
---

# Full Stop

Same work as `full-send`, and stop at the gate. Read
[full-send](../full-send/SKILL.md) and follow it, including the T3 Code
requirement and step 0: finish the change, prove it, review it with `sol-loop`,
file the PR, and babysit it. An explicit "full stop" request is the permission
for that work and for full-send's testing permission. Its merge permission does
not apply here; the overrides below take precedence.

## No merging

You may commit, push, rebase, resolve conflicts, and use `--force-with-lease` on
this task's branch. Never merge, enable auto-merge, enter a merge queue, push to
the default branch, or delegate those actions. Disable existing auto-merge and
remove the PR from any queue before you start, and check again before each push.
Report those changes.

## Stop at the gate

Use full-send's merge gate as the readiness check, then replace its merge and
final report with a handoff.

- Proof and review must cover the final diff. Recheck behavior and meaningful
  conflict fixes before handing off.
- Fetch the default branch and verify the live PR: open, not a draft, head and
  base as expected, checks green, reviews settled, mergeable, and satisfying the
  base branch's freshness rule.
- **Ready:** the gate passes. Leave the PR open and unmerged.
- **Waiting for approval:** only a human approval is missing. Confirm that it
  really is the blocker.
- **Blocked:** say what prevents readiness, what you tried, and what is needed.

Call `unwatch_pull_request` before the handoff or a question. Report the PR
link, final head, verdict, proof, reviewer outcome, and remaining risks, and
state that the PR is open and unmerged.
