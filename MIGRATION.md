# Flint migration notes

## Intentional decisions

- Distrobox is replaced by Nix development shells and is not migrated.
- Pimalaya is not migrated.
- Kitty is retired in favor of Ghostty.
- Mise, rbenv, and Livebook are not migrated for now.
- AeroSpace is macOS-only and is not migrated.
- Doom Emacs is retired. The straight.el configuration is managed from
  `home/emacs/` instead.
- The YADM encrypted archive is not configuration. Secrets remain outside the
  repository and should use `pass` or a future SOPS/age setup.

## Preserved behavior

- Git uses the personal identity by default and switches to the Alergeek
  identity for repositories under `~/projects/alergeek/` and
  `~/Developer/alergeek/`.
- Git aliases, git-absorb settings, difftastic, Git LFS, and tmux pane/status
  settings from Flint are represented in Home Manager.
- The straight.el Emacs configuration is installed at `~/.emacs.d`. Home
  Manager manages only its three source files, leaving straight.el's package
  directories writable.

## Known tradeoffs

- straight.el bootstraps and updates packages from upstream at runtime, so its
  package set is not Nix-reproducible. The first startup requires network
  access.
- The legacy Emacs configuration was adjusted for Emacs 30 by preferring
  `display-line-numbers-mode`; `linum-mode` no longer exists there.
- Hyprland includes a local parity patch. It has a successful NixOS build but
  still requires interactive desktop validation for monitor/workspace and
  gesture behavior.
