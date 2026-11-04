{
  config,
  lib,
  pkgs,
  ...
}:
let
  servers = config.programs.agents.mcpServers;
  trustedProjects = map (
    path: "${config.home.homeDirectory}/${path}"
  ) config.programs.agents.codexTrustedProjects;
  claudeDirectory =
    config.home.sessionVariables.CLAUDE_CONFIG_DIR or "${config.home.homeDirectory}/.claude";
  claudeState =
    if config.home.sessionVariables ? CLAUDE_CONFIG_DIR then
      "${claudeDirectory}/.claude.json"
    else
      "${config.home.homeDirectory}/.claude.json";
  codexDirectory = config.home.sessionVariables.CODEX_HOME or "${config.home.homeDirectory}/.codex";
  python = pkgs.python3.withPackages (ps: [ ps.tomlkit ]);
in
{
  options.programs.agents.mcpServers = lib.mkOption {
    type = with lib.types; attrsOf (nonEmptyListOf str);
    default = { };
    description = "Local stdio MCP servers registered for Claude Code, Codex and OpenCode, as commands.";
  };

  options.programs.agents.codexTrustedProjects = lib.mkOption {
    type = with lib.types; listOf str;
    default = [ ];
    description = "Repositories, relative to the home directory, whose project .codex/config.toml Codex loads; their linked worktrees follow the main checkout.";
  };

  config = lib.mkIf (servers != { } || trustedProjects != [ ]) {
    # These files stay writable for the clients; own only the declared entries.
    home.activation.agentMcpServers = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      run ${python}/bin/python3 - ${
        lib.escapeShellArgs [
          claudeState
          "${codexDirectory}/config.toml"
        ]
      } <<'PY'
      import json
      import pathlib
      import sys
      import tomlkit

      servers = json.loads(${builtins.toJSON (builtins.toJSON servers)})
      trusted = json.loads(${builtins.toJSON (builtins.toJSON trustedProjects)})
      claude_path, codex_path = map(pathlib.Path, sys.argv[1:])
      claude = json.loads(claude_path.read_text()) if claude_path.exists() else {}
      codex = tomlkit.loads(codex_path.read_text()) if codex_path.exists() else tomlkit.document()
      if servers and "mcp_servers" not in codex:
          codex.add("mcp_servers", tomlkit.table())
      if trusted and "projects" not in codex:
          codex.add("projects", tomlkit.table())
      for path in trusted:
          codex["projects"].setdefault(path, tomlkit.table())["trust_level"] = "trusted"
      for name, command in servers.items():
          claude.setdefault("mcpServers", {})[name] = {
              "type": "stdio", "command": command[0], "args": command[1:]
          }
          codex["mcp_servers"][name] = {"command": command[0], "args": command[1:]}
      files = [(codex_path, tomlkit.dumps(codex))]
      if servers:
          files.append((claude_path, json.dumps(claude, indent=2) + "\n"))
      for path, text in files:
          path.parent.mkdir(parents=True, exist_ok=True)
          if not path.exists() or path.read_text() != text:
              path.write_text(text)
              path.chmod(0o600)
      PY
    '';
  };
}
