{
  config,
  lib,
  pkgs,
  ...
}:
let
  servers = config.programs.agents.mcpServers;
  gatewayServers = lib.genAttrs config.programs.agents.mcpGatewayServers (name: {
    name = "gw-${name}";
    url = "${(import ../../mcp-gateway/settings.nix).baseURL}/${name}/mcp";
  });
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
  options.programs.agents = {
    mcpServers = lib.mkOption {
      type = with lib.types; attrsOf (nonEmptyListOf str);
      default = { };
      description = "Local stdio MCP servers registered for Claude Code, Codex and OpenCode, as commands.";
    };

    mcpGatewayServers = lib.mkOption {
      type = with lib.types; listOf (strMatching "[a-zA-Z0-9_-]+");
      default = [ ];
      description = "Gateway server names exposed globally to Claude Code, Codex and OpenCode with a gw- client prefix. Removed entries in writable client configs must be deleted manually.";
    };

    codexTrustedProjects = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      description = "Repositories, relative to the home directory, whose project .codex/config.toml Codex loads; their linked worktrees follow the main checkout.";
    };

  };

  config = lib.mkIf (servers != { } || gatewayServers != { } || trustedProjects != [ ]) {
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
      gateway = json.loads(${builtins.toJSON (builtins.toJSON gatewayServers)})
      trusted = json.loads(${builtins.toJSON (builtins.toJSON trustedProjects)})
      claude_path, codex_path = map(pathlib.Path, sys.argv[1:])
      claude = json.loads(claude_path.read_text()) if claude_path.exists() else {}
      claude_before = json.loads(json.dumps(claude))
      codex = tomlkit.loads(codex_path.read_text()) if codex_path.exists() else tomlkit.document()
      if (servers or gateway) and "mcp_servers" not in codex:
          codex.add("mcp_servers", tomlkit.table())
      if trusted and "projects" not in codex:
          codex.add("projects", tomlkit.table())
      for path in trusted:
          codex["projects"].setdefault(path, tomlkit.table())["trust_level"] = "trusted"
      for name, command in servers.items():
          claude.setdefault("mcpServers", {})[name] = {
              "type": "stdio", "command": command[0], "args": command[1:]
          }
          entry = {"command": command[0], "args": command[1:]}
          if codex["mcp_servers"].get(name) != entry:
              codex["mcp_servers"][name] = entry
      for server in gateway.values():
          name, url = server["name"], server["url"]
          claude.setdefault("mcpServers", {})[name] = {
              "type": "http", "url": url,
              "headers": {"Authorization": "Bearer ''${MCP_GATEWAY_TOKEN}"}
          }
          entry = {"url": url, "bearer_token_env_var": "MCP_GATEWAY_TOKEN"}
          if codex["mcp_servers"].get(name) != entry:
              codex["mcp_servers"][name] = entry
      files = [(codex_path, tomlkit.dumps(codex))]
      # Claude rewrites this file itself; touch it only when a managed entry changed.
      if (servers or gateway) and claude != claude_before:
          files.append((claude_path, json.dumps(claude, indent=2, ensure_ascii=False)))
      for path, text in files:
          path.parent.mkdir(parents=True, exist_ok=True)
          if not path.exists() or path.read_text() != text:
              path.write_text(text)
              path.chmod(0o600)
      PY
    '';
  };
}
