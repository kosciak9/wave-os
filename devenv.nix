{
  pkgs,
  inputs,
  config,
  ...
}:

let
  betterleaksPrePushMultiRefGuard = pkgs.writeShellScript "betterleaks-pre-push-multi-ref-guard" ''
    set -eu

    updates=0
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      updates=$((updates + 1))
    done

    if [ "$updates" -gt 1 ]; then
      printf '%s\n' 'betterleaks: push one ref at a time' >&2
      exit 1
    fi
  '';

  betterleaksPrePush = pkgs.writeShellApplication {
    name = "betterleaks-pre-push";
    runtimeInputs = [
      pkgs.betterleaks
      pkgs.git
    ];
    text = ''
      set -euo pipefail

      from="''${PRE_COMMIT_FROM_REF:-}"
      to="''${PRE_COMMIT_TO_REF:-}"
      oid_pattern='^([0-9a-f]{40}|[0-9a-f]{64})$'

      if [[ -z "$to" || ! "$to" =~ $oid_pattern ]]; then
        printf 'betterleaks: invalid or missing PRE_COMMIT_TO_REF\n' >&2
        exit 1
      fi

      if [[ -n "$from" && ! "$from" =~ $oid_pattern ]]; then
        printf 'betterleaks: invalid PRE_COMMIT_FROM_REF\n' >&2
        exit 1
      fi

      if [[ -n "$from" ]]; then
        betterleaks git . --log-opts="--full-history $from..$to" --redact --ignore-gitleaks-allow
      else
        betterleaks git . --log-opts="--full-history $to" --redact --ignore-gitleaks-allow
      fi
    '';
  };

in
{
  packages = with pkgs; [
    betterleaks
    deadnix
    jq
    nil
    nix-diff
    nix-eval-jobs
    nix-fast-build
    nix-inspect
    nix-melt
    nix-output-monitor
    nix-tree
    nixd
    nixfmt
    nvd
    statix
    python3
    inputs.deploy-rs.packages.${pkgs.stdenv.hostPlatform.system}.deploy-rs
  ];

  git-hooks = {
    package = pkgs.prek;
    hooks.betterleaks = {
      enable = true;
      entry = "${betterleaksPrePush}/bin/betterleaks-pre-push";
      stages = [ "pre-push" ];
      pass_filenames = false;
      always_run = true;
    };
  };

  tasks."betterleaks:prepare-worktree-hooks" = {
    before = [ "devenv:git-hooks:install" ];
    exec = ''
      set -euo pipefail

      git="${pkgs.git}/bin/git"
      if ! "$git" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        exit 0
      fi

      git_dir="$($git rev-parse --path-format=absolute --git-dir)"
      hooks_path="$git_dir/hooks"
      current_hooks_path="$($git config --get core.hooksPath || true)"
      if [[ -n "$current_hooks_path" && "$current_hooks_path" != "$hooks_path" ]]; then
        printf 'devenv: refusing to replace existing core.hooksPath: %s\n' "$current_hooks_path" >&2
        exit 1
      fi

      "$git" config extensions.worktreeConfig true
      "$git" config --worktree core.hooksPath "$hooks_path"
    '';
  };

  tasks."betterleaks:install-pre-push-guard" = {
    after = [ "devenv:git-hooks:install" ];
    before = [ "devenv:enterShell" ];
    exec = ''
      set -euo pipefail

      git="${pkgs.git}/bin/git"
      coreutils="${pkgs.coreutils}/bin"
      guard="${betterleaksPrePushMultiRefGuard}"
      if ! "$git" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        exit 0
      fi

      git_dir="$($git rev-parse --path-format=absolute --git-dir)"
      legacy_hook="$git_dir/hooks/pre-push.legacy"
      if [ -e "$legacy_hook" ] || [ -L "$legacy_hook" ]; then
        if [ -L "$legacy_hook" ] && [ "$($coreutils/readlink "$legacy_hook")" = "$guard" ]; then
          exit 0
        fi
        printf 'devenv: refusing to replace existing pre-push.legacy\n' >&2
        exit 1
      fi

      "$coreutils/mkdir" -p "$git_dir/hooks"
      "$coreutils/ln" -s "$guard" "$legacy_hook"
    '';
  };

  scripts = {
    wave.exec = ''
      exec ${pkgs.python3}/bin/python3 "${config.devenv.root}/tools/wave.py" "$@"
    '';

    nix-format.exec = ''
      set -euo pipefail
      if (($# > 0)); then
        nixfmt -- "$@"
      else
        files=()
        while IFS= read -r -d $'\0' file; do
          if [[ -f "$file" ]]; then
            files+=("$file")
          fi
        done < <(git ls-files --cached --others --exclude-standard -z -- '*.nix')
        if ((''${#files[@]} > 0)); then
          nixfmt -- "''${files[@]}"
        fi
      fi
    '';

    nix-check.exec = ''
      set -euo pipefail
      files=()
      while IFS= read -r -d $'\0' file; do
        if [[ -f "$file" ]]; then
          files+=("$file")
        fi
      done < <(git ls-files --cached --others --exclude-standard -z -- '*.nix')
      if ((''${#files[@]} > 0)); then
        nixfmt --check -- "''${files[@]}"
      fi
      statix check .
      deadnix --fail .
    '';

    nix-eval.exec = ''
      set -euo pipefail
      if (($# != 1)); then
        printf 'Usage: nix-eval jayce|renekton|all\n' >&2
        exit 2
      fi

      eval_target() {
        target="$1"
        printf 'Evaluating target: %s\n' "$target"
        nix eval --no-write-lock-file --show-trace --raw "$target"
        printf '\n'
      }

      case "$1" in
        jayce)
          eval_target 'path:.#nixosConfigurations.jayce.config.system.build.toplevel.drvPath'
          ;;
        renekton)
          eval_target 'path:.#darwinConfigurations.renekton.system.drvPath'
          ;;
        all)
          eval_target 'path:.#nixosConfigurations.jayce.config.system.build.toplevel.drvPath'
          eval_target 'path:.#darwinConfigurations.renekton.system.drvPath'
          ;;
        *)
          printf 'Usage: nix-eval jayce|renekton|all\n' >&2
          exit 2
          ;;
      esac
    '';
  };
}
