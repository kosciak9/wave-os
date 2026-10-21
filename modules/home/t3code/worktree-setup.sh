set -eu

hooks='
if [ -f .config/wt.toml ]; then
  wt hook pre-start --yes
  wt hook post-start --yes
  wt hook post-switch --yes
fi
'

if [ -f devenv.nix ]; then
  devenv shell -- bash -euc "$hooks"
elif [ -f .config/wt.toml ]; then
  bash -euc "$hooks"
fi
