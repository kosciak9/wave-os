{
  inputs,
  lib,
  pkgs,
  config,
  ...
}:

let
  plugins = (import ./plugins.nix { inherit pkgs lib; }) // config.programs.herdr.extraPlugins;
  herdr = inputs.herdr.packages.${pkgs.stdenv.hostPlatform.system}.default.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [
      ./patches/worktrunk-context-menu.patch
      ./patches/agents-pane-title.patch
    ];
  });
  herdrWorktrunk = pkgs.applyPatches {
    name = "herdr-worktrunk";
    src = inputs.herdr-worktrunk;
    patches = [ ./patches/worktrunk-target-pane.patch ];
  };
  claudeDirectory =
    config.home.sessionVariables.CLAUDE_CONFIG_DIR or "${config.home.homeDirectory}/.claude";
  claudeSettings = pkgs.writeText "claude-settings.json" (
    builtins.toJSON {
      "$schema" = "https://json.schemastore.org/claude-code-settings.json";
      disableAgentView = true;
      theme = "custom:kanagawa";
      spinnerTipsEnabled = false;
      spinnerVerbs = {
        mode = "replace";
        verbs = [ "Working" ];
      };
      showTurnDuration = false;
      prefersReducedMotion = true;
      terminalProgressBarEnabled = false;
      promptSuggestionEnabled = false;
      awaySummaryEnabled = false;
      emojiCompletionEnabled = false;
      tui = "fullscreen";
      viewMode = "focus";
    }
  );
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
  herdrLinux = pkgs.stdenv.hostPlatform.isLinux;
  herdrDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  herdrLogDirectory = "${config.xdg.stateHome}/herdr";
  herdrDarwinStart = pkgs.writeShellScript "herdr-default-server" ''
    set -eu
    # Source preflights also make source-only updates change the launchd plist.
    test -r ${lib.escapeShellArg "${herdrWorktrunk}/herdr-plugin.toml"}
    ${lib.concatMapStringsSep "\n" (
      plugin: "test -r ${lib.escapeShellArg "${plugin}/herdr-plugin.toml"}"
    ) (lib.attrValues plugins)}
    test -r ${lib.escapeShellArg "${inputs.herdr}/Cargo.toml"}
    ${lib.getExe herdr} --session default server stop || true
    exec ${lib.getExe herdr} --session default server
  '';
in
{
  imports = [
    ./federation.nix
    ./plugin-options.nix
  ];

  programs.worktrunk = {
    enable = true;
    enableZshIntegration = true;
    package = worktrunk;
  };

  xdg.configFile."herdr/config.toml".text = ''
    onboarding = false

    [session]
    resume_agents_on_restore = true

    [experimental]
    pane_history = true

    [theme]
    name = "kanagawa"

    [ui.sidebar.agents]
    rows = [["pane"], ["workspace", "machine", "agent"]]

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

    [[keys.command]]
    key = "prefix+shift+u"
    type = "plugin_action"
    command = "herdr-agent-usage.open"
    description = "Agent limits dashboard"
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

  systemd.user.services.herdr = lib.mkIf herdrLinux {
    Unit = {
      Description = "Herdr default session";
      X-Restart-Triggers = [
        herdr
        (toString inputs.herdr)
        (toString herdrWorktrunk)
        (toString config.xdg.configFile."herdr/config.toml".source)
      ]
      ++ lib.attrValues plugins;
    };
    Service = {
      Type = "simple";
      Environment = [
        (lib.escapeShellArg "HERDR_CONFIG_PATH=${
          toString config.xdg.configFile."herdr/config.toml".source
        }")
        (lib.escapeShellArg "XDG_CONFIG_HOME=${config.xdg.configHome}")
        (lib.escapeShellArg "SHELL=${lib.getExe config.programs.zsh.package}")
        (lib.escapeShellArg "PATH=${
          lib.makeBinPath [
            pkgs.coreutils
            pkgs.bash
          ]
        }:${config.home.profileDirectory}/bin:/etc/profiles/per-user/${config.home.username}/bin:/run/current-system/sw/bin:/usr/bin:/bin")
      ];
      ExecStartPre = "-${lib.getExe herdr} --session default server stop";
      ExecStart = "${lib.getExe herdr} --session default server";
      ExecStop = "${lib.getExe herdr} --session default server stop";
      Restart = "on-failure";
      RestartSec = 3;
      KillSignal = "SIGINT";
      KillMode = "mixed";
      TimeoutStopSec = 30;
    };
    Install.WantedBy = [ "default.target" ];
  };

  launchd.agents.herdr = lib.mkIf herdrDarwin {
    enable = true;
    domain = "user";
    config = {
      ProgramArguments = [ (toString herdrDarwinStart) ];
      EnvironmentVariables = {
        HERDR_CONFIG_PATH = toString config.xdg.configFile."herdr/config.toml".source;
        XDG_CONFIG_HOME = config.xdg.configHome;
        HOME = config.home.homeDirectory;
        SHELL = lib.getExe config.programs.zsh.package;
        PATH = "${
          lib.makeBinPath [
            pkgs.coreutils
            pkgs.bash
          ]
        }:${config.home.profileDirectory}/bin:/etc/profiles/per-user/${config.home.username}/bin:/run/current-system/sw/bin:/usr/bin:/bin:/usr/sbin:/sbin";
      };
      RunAtLoad = true;
      KeepAlive.SuccessfulExit = false;
      ExitTimeOut = 30;
      ThrottleInterval = 3;
      ProcessType = "Standard";
      StandardOutPath = "${herdrLogDirectory}/default.out.log";
      StandardErrorPath = "${herdrLogDirectory}/default.err.log";
    };
  };

  home = {
    file."claude-kanagawa-theme" = {
      target = "${claudeDirectory}/themes/kanagawa.json";
      text = builtins.toJSON (import ./claude-kanagawa.nix);
    };

    packages = with pkgs; [
      herdr
      antigravity-cli
      bash
      claude-code
      codex
      fzf
      jq
      python3
    ];

    activation = {
      # Settings and hook assets remain writable for upstream integrations.
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

      claudeSettings = lib.hm.dag.entryAfter [ "herdrIntegrations" ] ''
        run ${pkgs.python3}/bin/python3 - ${lib.escapeShellArg "${claudeDirectory}/settings.json"} ${claudeSettings} <<'PY'
        import json
        import pathlib
        import sys

        path = pathlib.Path(sys.argv[1])
        settings = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
        settings.update(json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")))
        path.write_text(json.dumps(settings, indent=2) + "\n", encoding="utf-8")
        PY
      '';

      # Nix owns registration and enabled state; Herdr manages the mutable registry.
      herdrWorktrunk = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
        run ${lib.getExe herdr} plugin link ${lib.escapeShellArg (toString herdrWorktrunk)} --enabled
      '';

      herdrPluginReconciliation = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
        (
          registered=$(${lib.getExe herdr} --session default plugin list --json) || exit $?
          removed=$(HERDR_REGISTERED_PLUGINS="$registered" ${pkgs.python3}/bin/python3 - ${lib.escapeShellArgs (map toString (lib.attrValues plugins))} <<'PY'
        import json
        import os
        import pathlib
        import re
        import sys
        import tomllib

        desired = {tomllib.loads((pathlib.Path(root) / "herdr-plugin.toml").read_text())["id"]
                   for root in sys.argv[1:]}
        registered = json.loads(os.environ["HERDR_REGISTERED_PLUGINS"])["result"]["plugins"]
        for plugin in registered:
            root = pathlib.Path(plugin["plugin_root"])
            if (plugin["source"]["kind"] == "local"
                    and root.parent == pathlib.Path(${builtins.toJSON builtins.storeDir})
                    and re.fullmatch(r"[a-z0-9]{32}-herdr-[a-z0-9-]+-plugin", root.name)
                    and plugin["plugin_id"] not in desired):
                print(plugin["plugin_id"])
        PY
          ) || exit $?
          while IFS= read -r plugin; do
            [ -n "$plugin" ] || continue
            run ${lib.getExe herdr} --session default plugin uninstall "$plugin" || exit $?
          done <<< "$removed"
        )
      '';

      herdrPlugins = lib.hm.dag.entryAfter [ "herdrPluginReconciliation" ] (
        lib.concatMapStringsSep "\n" (plugin: ''
          run ${lib.getExe herdr} plugin link ${lib.escapeShellArg (toString plugin)} --enabled
        '') (lib.attrValues plugins)
      );

      herdrServicesReady = lib.mkIf herdrLinux (
        lib.hm.dag.entryBetween [ "reloadSystemd" ] [ "herdrIntegrations" "herdrWorktrunk" "herdrPlugins" ]
          ""
      );

      herdrDarwinLogDirectory = lib.mkIf herdrDarwin (
        lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          run ${pkgs.coreutils}/bin/mkdir -p -- ${lib.escapeShellArg herdrLogDirectory}
        ''
      );

      herdrDarwinServicesReady = lib.mkIf herdrDarwin (
        lib.hm.dag.entryBetween
          [ "setupLaunchAgents" ]
          [ "herdrIntegrations" "herdrWorktrunk" "herdrPlugins" "herdrDarwinLogDirectory" ]
          ""
      );
    };
  };
}
