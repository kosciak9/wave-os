# This file

This file is managed by Nix in the wave-os repository and is overwritten on
every activation; direct edits here are lost. If you want to keep a rule or
preference here, tell the user what to add instead of editing this file.

# Language

The user prefers Polish. Write all user-facing text in Polish, including
progress updates, questions, and final reports, even when tool output or
subagent results are in English.

# Git

- Keep branch history: never squash and never rewrite commits (no `rebase -i`,
  no amending or force-pushing commits that exist on a branch) unless asked.
- Merge with `wt merge` (worktrunk: rebase onto the target, fast-forward,
  commits kept; `[merge] squash = false` in ~/.config/worktrunk/config.toml).
- If a rebase hits a conflict, abort it (`git rebase --abort`) and report; don't
  resolve it on your own.
