{ config, ... }:
let
  claudeDirectory =
    config.home.sessionVariables.CLAUDE_CONFIG_DIR or "${config.home.homeDirectory}/.claude";
  codexDirectory = config.home.sessionVariables.CODEX_HOME or "${config.home.homeDirectory}/.codex";
  skills = {
    source = ./skills;
    force = true;
    recursive = true;
  };
in
{
  home.file = {
    ".agents/skills" = skills;
    "claude-skills" = skills // {
      target = "${claudeDirectory}/skills";
    };
    "claude-instructions" = {
      text = builtins.readFile ./CLAUDE.md + "\n" + builtins.readFile ./AGENTS.md;
      target = "${claudeDirectory}/CLAUDE.md";
      force = true;
    };
    "codex-instructions" = {
      source = ./AGENTS.md;
      target = "${codexDirectory}/AGENTS.md";
      force = true;
    };
  };
  xdg.configFile."opencode/AGENTS.md" = {
    source = ./AGENTS.md;
    force = true;
  };
}
