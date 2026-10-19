{
  config,
  osConfig,
  lib,
  pkgs,
  ...
}:
let
  gatewayPackage = import ../../../packages/agent-gateway.nix {
    inherit lib pkgs;
    apiKeyFile = osConfig.sops.secrets."cliproxyapi/api-key".path;
    baseUrlFile = osConfig.sops.secrets."cliproxyapi/base-url".path;
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
      autoCompactEnabled = true;
      emojiCompletionEnabled = false;
      tui = "fullscreen";
      viewMode = "focus";
      # Empty strings hide the trailers; booleans fail the schema and are ignored.
      attribution = {
        commit = "";
        pr = "";
      };
      # Smaller-context models otherwise drop rarely used skill descriptions.
      skillListingBudgetFraction = 0.02;
      # Skills come from the shared Nix-managed set, not the claude.ai account.
      syncClaudeAiSkills = false;
      # Agents browse through the camofox-browser skill instead.
      skillOverrides.claude-in-chrome = "off";
    }
  );
in
{
  assertions = [
    {
      assertion = lib.hasPrefix "/" claudeDirectory;
      message = "Claude settings require CLAUDE_CONFIG_DIR to be an absolute path.";
    }
  ];

  programs.zsh.generatedCompletions.claude = "printf '%s\\n' '#compdef claude' '_gnu_generic'";

  home = {
    packages = [
      pkgs.bash
      (gatewayPackage pkgs.claude-code "claude")
      (gatewayPackage pkgs.codex "codex")
      pkgs.fzf
      pkgs.jq
      pkgs.python3
    ];

    file."claude-kanagawa-theme" = {
      target = "${claudeDirectory}/themes/kanagawa.json";
      text = builtins.toJSON (import ./claude-kanagawa.nix);
    };

    activation.claudeSettings = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      run ${pkgs.python3}/bin/python3 - ${lib.escapeShellArg "${claudeDirectory}/settings.json"} ${claudeSettings} <<'PYTHON'
      import json
      import pathlib
      import sys

      path = pathlib.Path(sys.argv[1])
      if path.is_symlink() and not path.exists():
          sys.exit("Claude settings path is a dangling symlink")
      target = path.resolve()
      if target.is_relative_to(${builtins.toJSON builtins.storeDir}):
          sys.exit("Claude settings must remain writable outside the Nix store")
      original = json.loads(target.read_text(encoding="utf-8")) if target.exists() else {}
      if not isinstance(original, dict):
          sys.exit("Claude settings must be a JSON object")
      settings = {**original, **json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))}
      if settings != original:
          target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
          target.write_text(json.dumps(settings, indent=2) + "\n", encoding="utf-8")
      PYTHON
    '';

    activation.agentHarnessesReady = lib.hm.dag.entryBetween (
      if pkgs.stdenv.hostPlatform.isDarwin then [ "setupLaunchAgents" ] else [ "reloadSystemd" ]
    ) ([ "claudeSettings" ] ++ lib.optional config.programs.agents.cua.enable "cuaMcp") "";
  };
}
