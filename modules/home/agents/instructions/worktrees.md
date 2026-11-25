# Worktrees

Repository instructions may override this default. Before editing, check the
checkout and whether another task is already using it:

- On the default branch with a clean, available checkout, work there directly
  without asking.
- If another task is using the default checkout, including when it has unrelated
  uncommitted changes, create a clean linked worktree yourself with
  `wt switch --create <branch>` and work there. Leave the other task's changes
  in the original checkout.
- On another branch or in a linked worktree, stay there.
- Move the current task to a new worktree when the user requests it, preserving
  its changes. Do not ask about moving it by default.
