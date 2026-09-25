{
  pkgs,
  inputs,
  config,
  ...
}:
{
  packages = with pkgs; [
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
