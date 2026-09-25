# Agent guidance

- Home Manager installs `devenv` and `direnv` for the human's trusted-repo interactive auto-activation. Keep Zsh aliases and plugins in `modules/home/zsh`.
- Agents do not rely on direnv. Run project tools as `devenv shell -- <command>`; plain file and Git operations need no devenv. Ask the user only if direct devenv access itself fails.
- Generate or update `devenv.lock` only via devenv. Preserve `flake.lock` during validation with `--no-write-lock-file`; `path:.` includes unstaged new Nix files.
- Workflow: format with `devenv shell -- nix-format [files...]`, run cheap checks once with `devenv shell -- nix-check`, then evaluate affected configurations once with `devenv shell -- nix-eval jayce|renekton|all`. Do not run `devenv test`. `nix flake check --no-build --all-systems --no-write-lock-file path:.` is optional diagnostics, not a replacement for Darwin evaluation.
- Builds are separate and targeted, preceded by evaluation and preferably a dry-run; do not routinely build the full fleet.
- Do not add tests to the repository unless the user explicitly reverses this policy. Do not disable package or upstream build checks.
- Do not add persistent scripts for one-time bootstrap, setup, or migrations; give the user sequential terminal commands and remove completed migration paths. Distinguish runtime, recovery, and upgrade behavior.
- The user's activation workflow requires intended configuration changes to be committed before any switch; agents commit only when explicitly requested and never run switch commands without an explicit activation request. The system targets are `nixosConfigurations.jayce` and `darwinConfigurations.renekton`.
- This repository is public: never add or expose secrets, credentials, tokens, private keys, personal data, or private infrastructure details. Do not commit changes unless asked.
- Useful interactive tools include `devenv info`, `devenv eval`, `devenv repl`, `nixd`, `nil`, `nix-output-monitor`, `nix-tree`, `nix-diff`, `nix-eval-jobs`, `nix-fast-build`, `nix-inspect`, `nix-melt`, and `nvd`.

## Parallel work with Worktrunk

- Before editing, require a clean dedicated linked `wt` worktree. If the worktree is dirty (even if another one could be created), the current branch is `main`, or the current directory is the primary/main repository checkout, tell the user and ask them to create or open a clean dedicated `wt` worktree; do not implement until it is available. A clean linked task worktree is allowed. Use one separate `wt` worktree, branch, and PR per logical task, including non-concurrent work; avoid unrelated refactors, cleanup, and mass formatting.
- Never stash, reset, clean, restore, rewrite, or otherwise disturb another task's work; never rewrite or reset another branch, and never run repository-wide destructive operations. Do not delete or prune others' worktrees or rebase others' branches; independent PRs may touch the same files.
- Validate only your own worktree. Agents may update their own PR branch; resolve independent PR conflicts later while updating your own branch before merge. Keep history linear with rebase-only updates against current `main`, and create no squash or merge commits.
- When authorized to commit or push, amend and rebase only your own task branch; prefer one clean commit per logical change, use separate commits for genuinely distinct changes, and push rewritten PR history only with `--force-with-lease`—never rewrite other task branches or `main`, and do not retain implementation detours just to document the path.
- Keep PR descriptions concise: **What changed**, **Why**, and **Impact** (including affected hosts and user-visible runtime effect); add **Validation** only when meaningful and not merely routine CI. GitHub review and status policy is the merge gate and must not be bypassed.
- Never activate or switch system configurations unless explicitly requested.
