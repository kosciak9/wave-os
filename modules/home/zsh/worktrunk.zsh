# Keep Worktrunk's shell integration and completions for every non-Herdr command.
if (( $+functions[wt] )); then
  if (( ! $+functions[_wt_worktrunk] )); then
    functions[_wt_worktrunk]=$functions[wt]
  fi

  wt() {
    if [[ -z ${HERDR_WORKSPACE_ID:-} || -z ${HERDR_BIN_PATH:-} || -n ${COMPLETE:-} ]]; then
      _wt_worktrunk "$@"
      return
    fi

    local arg subcommand='' skip_value=false
    for arg in "$@"; do
      if [[ $skip_value == true ]]; then
        skip_value=false
        continue
      fi
      case $arg in
        --) break ;;
        # Explicit execution and development mode retain upstream shell semantics.
        -x*|--execute|--execute=*|--source|-h|--help)
          _wt_worktrunk "$@"
          return
          ;;
        -C|--config|--config-set) skip_value=true ;;
        -*) ;;
        *) [[ -n $subcommand ]] || subcommand=$arg ;;
      esac
    done

    if [[ $subcommand != switch ]]; then
      _wt_worktrunk "$@"
      return
    fi

    local cd_file checkout repo_record
    cd_file=$(command mktemp) || return
    {
      # Consume the same raw-path directive as upstream, but navigate Herdr, not this shell.
      if WORKTRUNK_DIRECTIVE_CD_FILE="$cd_file" WORKTRUNK_DIRECTIVE_EXEC_FILE='' \
        command "${WORKTRUNK_BIN:-wt}" "$@"; then
        [[ -s $cd_file ]] || return 0
      else
        return $?
      fi
      checkout=$(<"$cd_file")
      IFS= read -r -d '' repo_record < <(command git -C "$checkout" worktree list --porcelain -z)
      if [[ $repo_record != 'worktree '* ]]; then
        print -u2 -- 'wt: cannot determine the primary checkout for Herdr'
        return 1
      fi
      "$HERDR_BIN_PATH" worktree open --cwd "${repo_record#worktree }" \
        --path "$checkout" --focus >/dev/null
    } always {
      command rm -f -- "$cd_file"
    }
  }
fi
