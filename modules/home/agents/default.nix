{ config, ... }:
let
  claudeDirectory =
    config.home.sessionVariables.CLAUDE_CONFIG_DIR or "${config.home.homeDirectory}/.claude";
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
      source = ./CLAUDE.md;
      target = "${claudeDirectory}/CLAUDE.md";
      force = true;
    };
    ".gemini/antigravity-cli/skills" = skills;
  };
}
