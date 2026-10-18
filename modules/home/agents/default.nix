{ config, pkgs, ... }:
let
  earshot = pkgs.callPackage ../../../packages/earshot.nix { };
  earshotSkills = pkgs.runCommand "earshot-skills-${earshot.version}" { } ''
    mkdir -p "$out"
    cp -R ${earshot.src}/skills/earshot ${earshot.src}/skills/real-sound "$out/"
    chmod -R u+w "$out"
    substituteInPlace "$out/earshot/SKILL.md" \
      --replace-fail 'pip install -e "/path/to/earshot[mcp,llm]"' \
        '# Nix-managed: earshot and ffmpeg are already installed; do not use pip.' \
      --replace-fail '/path/to/earshot/.venv/bin/python' '${earshot.pythonEnvironment}/bin/python'
    substituteInPlace "$out/real-sound/SKILL.md" \
      --replace-fail '{{PY}}' '${earshot.pythonEnvironment}/bin/python'
  '';
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
  imports = [
    ./cua.nix
    ./harnesses.nix
    ../worktrunk.nix
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
  };
  xdg.configFile."opencode/AGENTS.md" = {
    source = ./AGENTS.md;
    force = true;
  };
}
