---
name: sol-loop
description:
  Review a change with GPT Sol in a loop until both sides agree, bounding rounds
  and scope. Use when the user says "sol loop", or as the review step of
  full-send and full-stop.
when_to_use:
  "'sol loop', 'niech Sol to sprawdzi', review before filing a PR, after a
  non-trivial fix."
---

# sol-loop

Make the change more correct before (or after) filing a PR by having GPT Sol
review it in a loop. Make the smallest possible change that answers a real
finding, and push back when the finding is wrong.

## Budget

- Three rounds by default. Round 1 is a full review; later rounds look only at
  changed code and open findings.
- Extend to five only for security, permissions, auth, data loss, or
  state/concurrency, while a blocker or should stays open with evidence, or when
  the user asks.
- Stop early when a round returns only nits. Declined nits and comment, doc, or
  format-only fixes need no new round.
- One reviewer only. Sol must not start subagents.
- Keep a ledger: id, severity, outcome, and usage when the harness returns it.
  Never invent usage numbers.

## 1. Scope

Run `git status --short`. Do not stash, discard, or include unrelated changes.
Limit review to this change's paths when they separate cleanly; otherwise stop
and ask.

Establish the base after fetching:

- PR: `gh pr view <n> --json baseRefName,headRefOid`, check out the branch only
  when the worktree is clean, confirm `HEAD` is the PR head, then use
  `git merge-base HEAD origin/<baseRefName>`.
- Local: `git merge-base HEAD origin/<default-branch>`, or a base the user
  names, or `HEAD` for uncommitted changes only. Read the default branch from
  `git symbolic-ref refs/remotes/origin/HEAD` instead of assuming `main`.

The change is base to working tree in those paths, including untracked files.
Use the same diff command in every round. State the intent and out-of-scope in
one or two sentences. Run the covering checks first; do not send code that this
change breaks, and note missing or pre-failing checks in the brief.

## 2. Start Sol

In T3 Code, call `orchestrator_capabilities`, pick the latest Sol unless the
user named a version, and start it with `delegate_task` every round
(`role: "review"`, `mode: "async"`). Save the `taskId`; use a new
`clientRequestId` per round. `childThreadId` is storage, not a review target:
never continue a review with `t3_thread_send`, `create_threads`, or
`t3_thread_launch`.

Outside T3 Code, use a native subagent configured to run Sol, and keep its ID.
If no route runs Sol, report the blocker. Do not substitute another model.

Do not edit the scoped files while the review runs, and do not start a second
reviewer. A timeout, error, or silence is not approval; cancel, confirm it
stopped, and restart with the ledger if needed.

Round brief:

```
Review only. Do not edit, commit, push, comment on PRs, or start subagents.
Repo: <abs path> Base: <sha> Intent: <intent> Out of scope: <scope>
Checks: <results>
See: git diff <base> [-- <paths>]; git status --short (read untracked).
Read surrounding code. Find bugs, broken callers, mismatch with intent.
Skip style unless it hides a bug. Hold to the smallest change.
Flag code, tests, or guards the intent does not need. Other paths, rare cases,
small perf, extra compat: nits.
blocker = intended case wrong. should = real bug callers will hit, in intent.
nit = the rest.
Reply:
VERDICT: APPROVE or CHANGES
S1 [blocker|should|nit] <file>:<line> <claim>. Fix: <suggestion> (stable ids)
```

## 3. Answer findings

Check each finding and its severity yourself. A separate path, a rare case, or a
small cost is a nit whatever label it arrived with.

- Agree: make the smallest fix. Prefer deleting or narrowing code over adding a
  lock, cache, helper, or option. Fix the case that happened, and add one
  focused test that fails without the fix when the intent needs it.
- Disagree: say why, with evidence (`file:line`, a test, command output).
- Out of scope or a nit: decline in one line and list it as a follow-up.

Update the ledger, re-run the checks, and compare `git diff --shortstat`. If the
review grew the diff, cut first. Never agree just to end the loop.

## 4. Next round

Start one only when budget remains and a blocker or should is open, behavior
code changed, or the approval does not cover the current behavior diff. Send the
same base diff, the ledger (`fixed:` / `disagree:` / `declined:` with evidence),
and the change since the last round. Tell Sol to look at open ids and changed
code only, and mark every old id as `resolved` or `still open: <reason>`.

## 5. Stop and ship

Agreed means `APPROVE` on the current behavior diff, no blocker or should open,
and no concern of your own. Stuck means an item stays disputed after two
replies, or the budget ends; show both sides in two or three lines each and let
the user decide. Budget end is not approval.

Do not push during the loop. Push after agreement only when the user asked to
push, ship, or update the PR. When you push to a PR, add a line to the PR
description in the PR's language:

- English:
  `Reviewed with sol-loop: <N> rounds with <model>. Sol verdict: approved`
- Polish:
  `Przejrzane przez sol-loop: <N> rund z <model>. Werdykt Sol: zaakceptowane`

Add `on <effort>` only when it is verified.

Report the rounds, the model, what Sol changed, diff size before and after, the
fixed and declined findings with reasons, usage if exposed, and whether you
pushed.
