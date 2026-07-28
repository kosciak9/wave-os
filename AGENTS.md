# Agent guidance

- Home Manager installs `devenv` and its native Zsh hook for trusted-repository auto-activation. Keep aliases and plugins in `modules/home/zsh`; do not duplicate or override them in devenv. You should have access to all devenv tools, if not - ask user to allow the directory.
- `devenv.lock` must be generated or updated by devenv, never manually authored.
- Validate in this order, from cheapest to most expensive: `nix-format`, `nix-format-check`, `nix-lint`, `nix-eval-config`, `nix-flake-check`, then `nix-validate`. Run `devenv test` for full validation.
- Prefer evaluation before builds. Preserve `flake.lock` during validation by using the provided scripts' `--no-write-lock-file` flags.
- Provided evaluation scripts use `path:.` so newly created, unstaged Nix files are included; do not stage files solely for Nix evaluation.
- Useful interactive tools include `devenv info`, `devenv eval`, `devenv repl`, `nixd`, `nil`, `nix-output-monitor`, `nix-tree`, `nix-diff`, `nix-eval-jobs`, `nix-fast-build`, `nix-inspect`, `nix-melt`, and `nvd`.
- Never run `nixos-rebuild switch`, `darwin-rebuild switch`, or `home-manager switch` unless the user explicitly requests activation.
- The flake targets are `nixosConfigurations.jayce`, `darwinConfigurations.renekton`, `homeConfigurations."kosciak@jayce"`, and `homeConfigurations."kosciak@renekton"`.
- Do not commit changes unless asked.
