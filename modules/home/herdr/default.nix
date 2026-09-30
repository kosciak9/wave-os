{
  inputs,
  lib,
  pkgs,
  config,
  ...
}:

let
  herdr = inputs.herdr.packages.${pkgs.stdenv.hostPlatform.system}.default;
  claudeDirectory =
    config.home.sessionVariables.CLAUDE_CONFIG_DIR or "${config.home.homeDirectory}/.claude";
  codexDirectory = config.home.sessionVariables.CODEX_HOME or "${config.home.homeDirectory}/.codex";
  antigravityDirectory =
    config.home.sessionVariables.ANTIGRAVITY_CLI_CONFIG_DIR
      or "${config.home.homeDirectory}/.gemini/config";
  worktrunk = pkgs.worktrunk.overrideAttrs {
    # TODO: Re-enable checks when Worktrunk process-table tests support Darwin sandboxes.
    # Darwin sandboxes hide the process table, breaking upstream shell-probe tests.
    # Skip the slow test suite there; Linux keeps the nixpkgs checks enabled.
    doCheck = !pkgs.stdenv.hostPlatform.isDarwin;
  };
in
{
  xdg.configFile."herdr/config.toml".text = ''
    onboarding = false

    [theme]
    name = "kanagawa"

    [[keys.command]]
    key = "prefix+shift+g"
    type = "plugin_action"
    command = "worktrunk.open"
    description = "Worktree: switch or create from default branch"

    [[keys.command]]
    key = "prefix+shift+c"
    type = "plugin_action"
    command = "worktrunk.open-current"
    description = "Worktree: switch or create from current branch"

    [[keys.command]]
    key = "prefix+shift+r"
    type = "plugin_action"
    command = "worktrunk.open-with-remotes"
    description = "Worktree: switch or create from remote branch"

    [[keys.command]]
    key = "prefix+shift+d"
    type = "plugin_action"
    command = "worktrunk.remove"
    description = "Worktree: remove"
  '';

  assertions = [
    {
      assertion = lib.all (lib.hasPrefix "/") [
        claudeDirectory
        codexDirectory
        antigravityDirectory
      ];
      message = "Herdr requires CLAUDE_CONFIG_DIR, CODEX_HOME, and ANTIGRAVITY_CLI_CONFIG_DIR to be declared as absolute paths (for example ${config.home.homeDirectory}/.claude, ${config.home.homeDirectory}/.codex, and ${config.home.homeDirectory}/.gemini/config); relative paths, tilde, and shell-variable expansion are unsupported.";
    }
  ];

  home = {
    packages = with pkgs; [
      herdr
      antigravity-cli
      bash
      claude-code
      codex
      fzf
      jq
      python3
      worktrunk
    ];

    activation = {
      # Upstream owns these mutable settings and hook assets, not Home Manager links.
      herdrIntegrations = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
        (
          claude=${lib.escapeShellArg claudeDirectory}
          codex=${lib.escapeShellArg codexDirectory}
          antigravity=${lib.escapeShellArg antigravityDirectory}
          directories=("$claude" "$claude/hooks" "$codex" "$antigravity" "$antigravity/hooks")
          files=("$claude/settings.json" "$claude/hooks/herdr-agent-state.sh"
            "$codex/config.toml" "$codex/hooks.json" "$codex/herdr-agent-state.sh"
            "$antigravity/hooks.json" "$antigravity/hooks/herdr-agent-state.sh")

          for path in "''${directories[@]}" "''${files[@]}"; do
            resolved=$(${pkgs.coreutils}/bin/realpath -m -- "$path") || exit $?
            case "$resolved" in
              ${lib.escapeShellArg builtins.storeDir}|${lib.escapeShellArg builtins.storeDir}/*)
                echo "Herdr integration refuses Nix-store-backed path: $path" >&2
                exit 1
                ;;
            esac
            if { [ -L "$path" ] && [ ! -e "$path" ]; } || { [ -e "$path" ] && [ ! -w "$path" ]; }; then
              echo "Herdr integration requires a writable path without a dangling symlink: $path" >&2
              exit 1
            fi
          done
          for path in "''${directories[@]}"; do
            if [ -e "$path" ] && [ ! -d "$path" ]; then
              echo "Herdr integration requires a directory: $path" >&2
              exit 1
            fi
          done
          for path in "''${files[@]}"; do
            if [ -e "$path" ] && [ ! -f "$path" ]; then
              echo "Herdr integration requires a regular file: $path" >&2
              exit 1
            fi
          done

          # Unsupported TOML shapes must not reach the pinned line-based Codex editor.
          if [ -e "$codex/config.toml" ]; then
            ${pkgs.python3}/bin/python3 - "$codex/config.toml" <<'PY' || exit $?
        import pathlib
        import re
        import sys
        import tomllib

        try:
            text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
            parsed = tomllib.loads(text)
            lines = text.splitlines()
            headers = [i for i, line in enumerate(lines)
                       if re.fullmatch(r"\[features\]\s*(?:#.*)?", line.strip())]
            if "features" not in parsed:
                if headers:
                    raise ValueError
            else:
                if len(headers) != 1 or not isinstance(parsed["features"], dict):
                    raise ValueError
                start = headers[0]
                end = next((i for i in range(start + 1, len(lines))
                            if lines[i].strip().startswith("[")), len(lines))
                for line in lines[start + 1:end]:
                    stripped = line.strip()
                    if stripped and not stripped.startswith("#") and not re.fullmatch(
                        r"[A-Za-z_][A-Za-z_0-9]*\s*=\s*(?:true|false)\s*(?:#.*)?", stripped
                    ):
                        raise ValueError
                block = tomllib.loads("\n".join(lines[start:end]))
                if block.get("features") != parsed["features"]:
                    raise ValueError
        except (OSError, ValueError):
            sys.exit("Herdr integration cannot safely edit Codex config.toml: require valid TOML and a plain [features] table containing only unquoted single-line boolean flags, or no features definition.")
        PY
          fi

          run ${pkgs.coreutils}/bin/mkdir -p -- "''${directories[@]}" || exit $?
          for integration in claude codex antigravity-cli; do
            run ${pkgs.coreutils}/bin/env CLAUDE_CONFIG_DIR="$claude" CODEX_HOME="$codex" \
              ANTIGRAVITY_CLI_CONFIG_DIR="$antigravity" ${lib.getExe herdr} integration install "$integration" || exit $?
          done
        )
      '';

      # Nix owns registration and enabled state; Herdr manages the mutable registry.
      herdrWorktrunk = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
        run ${lib.getExe herdr} plugin link ${lib.escapeShellArg (toString inputs.herdr-worktrunk)} --enabled
      '';
    };
  };
}
