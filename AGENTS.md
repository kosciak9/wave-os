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
