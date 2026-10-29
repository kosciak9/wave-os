{
  config,
  lib,
  pkgs,
  ...
}:
let
  servers = config.programs.agents.mcpServers;
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

  config = lib.mkIf (servers != { }) {
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
      claude_path, codex_path = map(pathlib.Path, sys.argv[1:])
      claude = json.loads(claude_path.read_text()) if claude_path.exists() else {}
      codex = tomlkit.loads(codex_path.read_text()) if codex_path.exists() else tomlkit.document()
      if "mcp_servers" not in codex:
          codex.add("mcp_servers", tomlkit.table())
      for name, command in servers.items():
          claude.setdefault("mcpServers", {})[name] = {
              "type": "stdio", "command": command[0], "args": command[1:]
          }
          codex["mcp_servers"][name] = {"command": command[0], "args": command[1:]}
      for path, text in (
          (claude_path, json.dumps(claude, indent=2) + "\n"),
          (codex_path, tomlkit.dumps(codex)),
      ):
          path.parent.mkdir(parents=True, exist_ok=True)
          if not path.exists() or path.read_text() != text:
              path.write_text(text)
              path.chmod(0o600)
      PY
    '';
  };
}
