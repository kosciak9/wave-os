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
      hash = "sha256-D+PWB+chLWxYByokGRYzQgYdz1y4m6EkPepZPX4zvg8=";
    };
    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp -R . "$out/"
      chmod -R u+w "$out"
      mkdir -p "$out/agents"
      cat > "$out/agents/openai.yaml" <<'YAML'
      interface:
        display_name: "CUA Driver"
        short_description: "Drive native GUI apps by accessibility tree or pixels"
        default_prompt: "Use $cua-driver to operate this application on the host."
      YAML
      runHook postInstall
    '';
  };
  claudeDirectory =
    config.home.sessionVariables.CLAUDE_CONFIG_DIR or "${config.home.homeDirectory}/.claude";
  mcpCommand = [
    (lib.getExe cuaDriver)
    "mcp"
    "--socket"
    "${config.xdg.cacheHome}/cua-driver/cua-driver.sock"
  ];
in
{
  options.programs.agents.cua.enable =
    lib.mkEnableOption "CUA desktop integrations for agent harnesses"
    // {
      default = pkgs.stdenv.hostPlatform.isLinux;
    };

  config = lib.mkIf config.programs.agents.cua.enable {
    programs.agents.mcpServers.cua-driver = mcpCommand;

    home = {
      file = {
        ".agents/skills/cua-driver".source = cuaSkills;
        "claude-cua-driver-skill" = {
          source = cuaSkills;
          target = "${claudeDirectory}/skills/cua-driver";
        };
      };
    };
  };
}
