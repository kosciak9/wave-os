{ pkgs, ... }:
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
  ];

  scripts = {
    nix-format.exec = ''
      set -euo pipefail
      git ls-files --cached --others --exclude-standard -z -- '*.nix' | while IFS= read -r -d $'\0' file; do
        nixfmt "$file"
      done
    '';

    nix-format-check.exec = ''
      set -euo pipefail
      git ls-files --cached --others --exclude-standard -z -- '*.nix' | while IFS= read -r -d $'\0' file; do
        nixfmt --check "$file"
      done
    '';

    nix-lint.exec = ''
      set -euo pipefail
      statix check .
      deadnix --fail .
    '';

    nix-eval-config.exec = ''
      set -euo pipefail
      targets=(
        'path:.#nixosConfigurations.jayce.config.system.build.toplevel.drvPath'
        'path:.#darwinConfigurations.renekton.system.drvPath'
        'path:.#homeConfigurations."kosciak@jayce".activationPackage.drvPath'
        'path:.#homeConfigurations."kosciak@renekton".activationPackage.drvPath'
      )
      for target in "''${targets[@]}"; do
        printf 'Evaluating target: %s\n' "$target"
        nix eval --no-write-lock-file --show-trace --raw "$target"
        printf '\n'
      done
    '';

    nix-flake-check.exec = ''
      set -euo pipefail
      nix flake check --no-build --all-systems --no-write-lock-file --show-trace path:.
    '';

    nix-validate.exec = ''
      set -euo pipefail
      nix-format-check
      nix-lint
      nix-eval-config
      nix-flake-check
    '';
  };

  enterTest = ''
    set -euo pipefail
    nix-validate
  '';
}
