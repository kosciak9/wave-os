{
  pkgs,
  inputs,
  lib,
  config,
  ...
}:

let
  betterleaksPrePush = pkgs.writeShellApplication {
    name = "betterleaks-pre-push";
    runtimeInputs = [
      pkgs.betterleaks
      pkgs.git
    ];
    text = ''
      exec betterleaks git . --log-opts="--all --full-history" --redact --ignore-gitleaks-allow
    '';
  };

in
{
  packages = with pkgs; [
    betterleaks
    cargo
    clippy
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
    prettier
    rustc
    rustfmt
    statix
    python3
    treefmt
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

  tasks."betterleaks:prepare-worktree-hooks" = lib.mkIf config.git-hooks.enable {
    before = [ "devenv:git-hooks:install" ];
    exec = ''
      set -euo pipefail

      git="${pkgs.git}/bin/git"
      if ! "$git" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        exit 0
      fi

      git_dir="$($git rev-parse --path-format=absolute --git-dir)"
      common_dir="$($git rev-parse --path-format=absolute --git-common-dir)"
      hooks_path="$git_dir/hooks"
      current_hooks_path="$($git config --get core.hooksPath || true)"
      if [[ -n "$current_hooks_path" && "$current_hooks_path" != "$hooks_path" ]]; then
        config_entry="$($git config --show-scope --show-origin --get core.hooksPath || true)"
        IFS=$'\t' read -r config_scope config_origin config_value <<< "$config_entry"
        stale_worktree=""
        inherited_primary_hooks=""
        if [[ "$config_scope" == worktree && "$config_origin" == file:*config.worktree && "$config_value" == "$current_hooks_path" && "$git_dir" != "$common_dir" && "$current_hooks_path" == "$common_dir/hooks" ]]; then
          # Replace only the exact primary checkout hook path inherited by a linked worktree.
          inherited_primary_hooks="yes"
        fi
        if [[ "$config_scope" == worktree && "$config_origin" == file:*config.worktree && "$config_value" == "$current_hooks_path" && "$current_hooks_path" == "$common_dir"/worktrees/*/hooks ]]; then
          stale_worktree="''${current_hooks_path#"$common_dir"/worktrees/}"
          stale_worktree="''${stale_worktree%/hooks}"
          if [[ "$stale_worktree" == */* || -z "$stale_worktree" || "$stale_worktree" == "''${git_dir##*/}" ]]; then
            stale_worktree=""
          elif [[ ! -f "$common_dir/worktrees/$stale_worktree/gitdir" ]]; then
            stale_worktree=""
          fi
        fi
        if [[ -z "$stale_worktree" && -z "$inherited_primary_hooks" ]]; then
          printf 'devenv: refusing to replace unexpected core.hooksPath: %s\n' "$current_hooks_path" >&2
          exit 1
        fi
      fi

      "$git" config extensions.worktreeConfig true
      "$git" config --worktree core.hooksPath "$hooks_path"
    '';
  };

  scripts = {
    format.exec = ''
      exec treefmt "$@"
    '';

    check.exec = ''
      exec nix-check "$@"
    '';

    nix-check.exec = ''
      set -euo pipefail
      treefmt --fail-on-change
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
