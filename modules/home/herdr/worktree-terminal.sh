source_checkout=$1
branch=$2
base=$3
shell=$4
shell_mode=$5
source_workspace=$6

open_shell() {
  export PATH="${shell_path:-$PATH}"
  if [[ ${HERDR_WORKTREE_TRUST:-} == 1 ]]; then
    unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 HERDR_WORKTREE_TRUST
  fi
  if [[ $shell_mode == login ]]; then
    exec "$shell" -l
  fi
  exec "$shell"
}

fail() {
  printf '\nWorktree preparation failed: %s\nThe terminal remains open; review the output above.\n\n' "$1" >&2
  open_shell
}

trap 'fail "interrupted"' INT
printf '\nPreparing worktree %s from %s\n\n' "$branch" "$base"
[[ $branch != -* ]] || fail "branch names cannot start with a dash"
git check-ref-format --branch "$branch" >/dev/null || fail "invalid branch name"

args=(switch --no-cd --format=json)
if git -C "$source_checkout" show-ref --verify --quiet "refs/heads/$branch"; then
  :
else
  status=$?
  [[ $status == 1 ]] || fail "cannot inspect the source branch (exit $status)"
  args+=(--create --base "$base")
fi

# Worktrunk keeps status and hook output on stderr in JSON mode, attached to
# this PTY. Only its machine-readable checkout path is captured.
if result=$(wt -C "$source_checkout" "${args[@]}" "$branch"); then
  :
else
  fail "wt switch exited with status $?"
fi
if checkout=$(jq -er '.path | select(type == "string" and startswith("/"))' <<<"$result"); then
  :
else
  printf '%s\n' "$result" >&2
  fail "Worktrunk did not return an absolute checkout path"
fi
[[ $(realpath -- "$checkout") != "$(realpath -- "$source_checkout")" ]] \
  || fail "the branch is already checked out in the source workspace"
cd -- "$checkout" || fail "cannot enter the checkout"

open_args=(worktree open --workspace "$source_workspace" --path "$checkout"
  --target-workspace "$HERDR_WORKSPACE_ID" --no-focus)
[[ ${HERDR_WORKTREE_TRUST:-} != 1 ]] || open_args+=(--trust-repository)
if response=$("$HERDR_BIN_PATH" "${open_args[@]}"); then
  printf '\nWorktree ready: %s\n\n' "$checkout"
else
  printf '%s\n' "$response" >&2
  fail "cannot register the checkout with Herdr"
fi
trap - INT
open_shell
