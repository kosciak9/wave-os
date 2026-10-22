set -eu

# T3 removes worktrees with plain `git worktree remove`, so Worktrunk's
# pre-remove hooks (stopping per-worktree services) run here, on settle.
hooks='
if [ -f .config/wt.toml ]; then
  wt hook pre-remove --yes
fi
'

if [ -f devenv.nix ]; then
  devenv shell -- bash -euc "$hooks"
elif [ -f .config/wt.toml ]; then
  bash -euc "$hooks"
fi
