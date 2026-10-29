{
  config,
  lib,
  pkgs,
  ...
}:
let
  securityAuditSource = pkgs.fetchFromGitHub {
    owner = "cloudflare";
    repo = "security-audit-skill";
    rev = "c1c8a8c1471069fb0e188eeaff69b8e8db6564a8";
    hash = "sha256-oVVACjotkHvllQGxEP8yWaEt4c3GxT0d909TUM5P3NM=";
  };
  securityAuditSkill = pkgs.runCommand "security-audit-skill" { } ''
    mkdir -p "$out/agents"
    cp -R ${securityAuditSource}/skills/security-audit/. "$out/"
    chmod -R u+w "$out"
    cat > "$out/agents/openai.yaml" <<'YAML'
    interface:
      display_name: "Security Audit"
      short_description: "Source-first vulnerability review and safe fixes"
      default_prompt: "Use $security-audit to review this code for vulnerabilities."
    YAML
  '';
  earshot = pkgs.callPackage ../../../packages/earshot.nix { };
  earshotSkills = pkgs.runCommand "earshot-skills-${earshot.version}" { } ''
    mkdir -p "$out"
    cp -R ${earshot.src}/skills/earshot ${earshot.src}/skills/real-sound "$out/"
    chmod -R u+w "$out"
    mkdir -p "$out/earshot/agents" "$out/real-sound/agents"
    cat > "$out/earshot/agents/openai.yaml" <<'YAML'
    interface:
      display_name: "Earshot"
      short_description: "Judge, choose, and verify audio by measuring it"
      default_prompt: "Use $earshot before telling me how this audio sounds."
    YAML
    cat > "$out/real-sound/agents/openai.yaml" <<'YAML'
    interface:
      display_name: "Real Sound"
      short_description: "Licensed music, foley, and SFX mixed to picture"
      default_prompt: "Use $real-sound to build the soundtrack for this video."
    YAML
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

  home.packages = [
    earshot
    pkgs.ffmpeg
  ];

  home.file = {
    ".agents/skills" = skills;
    ".agents/skills/earshot".source = "${earshotSkills}/earshot";
    ".agents/skills/real-sound".source = "${earshotSkills}/real-sound";
    ".agents/skills/security-audit".source = securityAuditSkill;
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
    "claude-security-audit-skill" = {
      source = securityAuditSkill;
      target = "${claudeDirectory}/skills/security-audit";
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
