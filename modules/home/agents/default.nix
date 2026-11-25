{
  config,
  lib,
  pkgs,
  ...
}:
let
  earshot = pkgs.callPackage ../../../packages/earshot.nix { };
  earshotSkills = pkgs.callPackage ../../../packages/earshot-skills.nix { inherit earshot; };
  claudeDirectory =
    config.home.sessionVariables.CLAUDE_CONFIG_DIR or "${config.home.homeDirectory}/.claude";
  codexDirectory = config.home.sessionVariables.CODEX_HOME or "${config.home.homeDirectory}/.codex";
  skills = {
    source = ./skills;
    force = true;
    recursive = true;
  };
  # Clauses every harness must receive, so the UI rules survive edits and rewraps.
  uiRules = [
    "# UI changes"
    "pass on the `UI changes` rules"
    "finish it by showing the change in the running app"
    "embed screenshots of the running app"
    "Add a short video when the change is about interaction"
    "Only screenshots and videos of the current code count"
    "If you cannot run or capture the UI, say so and fix that first."
  ];
  normalize =
    text:
    lib.concatStringsSep " " (
      lib.filter (s: lib.isString s && s != "") (builtins.split "[[:space:]]+" text)
    );
  instructions = {
    Claude = config.home.file."claude-instructions".source;
    Codex = config.home.file."codex-instructions".source;
    OpenCode = config.xdg.configFile."opencode/AGENTS.md".source;
  };
in
{
  imports = [
    ./cua.nix
    ./harnesses.nix
    ./mcp.nix
    ../worktrunk.nix
  ];

  # Repositories whose project MCP servers Codex must load like Claude Code and OpenCode do.
  programs.agents.codexTrustedProjects = [
    "Developer/alergeek/firmowid"
    "Developer/alergeek/tcg-cheap"
  ];

  assertions = lib.mapAttrsToList (
    harness: source:
    let
      text = normalize (builtins.readFile source);
      missing = lib.filter (rule: !lib.hasInfix rule text) uiRules;
    in
    {
      assertion = missing == [ ];
      message = "${harness} agent instructions lack UI rules: ${lib.concatStringsSep "; " missing}";
    }
  ) instructions;

  programs.agents.mcpGatewayServers = [
    "sentry"
    "posthog"
    "firmowid-anonymized"
    "tcg-cheap-prod"
    "context7"
    "parallel-search"
    "openseo"
  ];

  home.packages = [
    earshot
    pkgs.ffmpeg
  ];

  home.file = {
    ".agents/skills" = skills;
    ".agents/skills/earshot".source = "${earshotSkills}/earshot";
    ".agents/skills/real-sound".source = "${earshotSkills}/real-sound";
    "claude-skills" = skills // {
      target = "${claudeDirectory}/skills";
    };
    "claude-earshot-skill" = {
      source = "${earshotSkills}/earshot";
      target = "${claudeDirectory}/skills/earshot";
    };
    "claude-real-sound-skill" = {
      source = "${earshotSkills}/real-sound";
      target = "${claudeDirectory}/skills/real-sound";
    };
    "claude-instructions" = {
      source = ./AGENTS.md;
      target = "${claudeDirectory}/CLAUDE.md";
      force = true;
    };
    "codex-instructions" = {
      source = ./AGENTS.md;
      target = "${codexDirectory}/AGENTS.md";
      force = true;
    };
  }
  # Codex skips a skill whose SKILL.md is a symlink, as in the recursive
  # .agents/skills tree, but reads a skill directory that is one.
  // lib.mapAttrs' (
    name: _:
    lib.nameValuePair "codex-skill-${name}" {
      source = ./skills + "/${name}";
      target = "${codexDirectory}/skills/${name}";
    }
  ) (builtins.readDir ./skills);
  xdg.configFile."opencode/AGENTS.md" = {
    source = ./AGENTS.md;
    force = true;
  };
}
