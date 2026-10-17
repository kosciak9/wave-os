{
  config,
  lib,
  pkgs,
  ...
}:
let
  cuaDriver = pkgs.callPackage ../../../packages/cua-driver.nix { };
  cuaSkills = pkgs.stdenvNoCC.mkDerivation {
    pname = "cua-driver-skills";
    inherit (cuaDriver) version;
    src = pkgs.fetchurl {
      url = "https://github.com/trycua/cua/releases/download/cua-driver-rs-v${cuaDriver.version}/cua-driver-rs-v${cuaDriver.version}-skills.tar.gz";
      hash = "sha256-Uo5clcQ7/QPZ8Dm118+OqHgE1xrbuhOfrv8k6jFhzdY=";
    };
    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp -R . "$out/"
      runHook postInstall
    '';
  };
  claudeDirectory =
    config.home.sessionVariables.CLAUDE_CONFIG_DIR or "${config.home.homeDirectory}/.claude";
  claudeState =
    if config.home.sessionVariables ? CLAUDE_CONFIG_DIR then
      "${claudeDirectory}/.claude.json"
    else
      "${config.home.homeDirectory}/.claude.json";
  codexDirectory = config.home.sessionVariables.CODEX_HOME or "${config.home.homeDirectory}/.codex";
  mcpCommand = [
    (lib.getExe cuaDriver)
    "mcp"
    "--socket"
    "${config.xdg.cacheHome}/cua-driver/cua-driver.sock"
  ];
  python = pkgs.python3.withPackages (ps: [ ps.tomlkit ]);
in
{
  options.programs.agents.cua.enable =
    lib.mkEnableOption "CUA desktop integrations for agent harnesses"
    // {
      default = pkgs.stdenv.hostPlatform.isLinux;
    };

  config = lib.mkIf config.programs.agents.cua.enable {
    home = {
      file = {
        ".agents/skills/cua-driver".source = cuaSkills;
        "claude-cua-driver-skill" = {
          source = cuaSkills;
          target = "${claudeDirectory}/skills/cua-driver";
        };
      };

      # These files stay writable for the clients and Herdr; own only the CUA entry.
      activation.cuaMcp = lib.hm.dag.entryAfter [ "herdrIntegrations" ] ''
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

        command = json.loads(${builtins.toJSON (builtins.toJSON mcpCommand)})
        claude_path, codex_path = map(pathlib.Path, sys.argv[1:])
        claude = json.loads(claude_path.read_text()) if claude_path.exists() else {}
        codex = tomlkit.loads(codex_path.read_text()) if codex_path.exists() else tomlkit.document()
        claude.setdefault("mcpServers", {})["cua-driver"] = {
            "type": "stdio", "command": command[0], "args": command[1:]
        }
        if "mcp_servers" not in codex:
            codex.add("mcp_servers", tomlkit.table())
        codex["mcp_servers"]["cua-driver"] = {
            "command": command[0], "args": command[1:]
        }
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
  };
}
