{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  gateway = pkgs.callPackage ../../../packages/mcp-gateway.nix {
    apiKeyFile = osConfig.sops.secrets."mcp-gateway/api-key".path;
  };
  logDirectory = "${config.home.homeDirectory}/Library/Logs/MCPGateway";
in
{
  config = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
    home.packages = [ gateway ];
    home.activation.mcpGatewayDirectories =
      lib.hm.dag.entryBetween [ "setupLaunchAgents" ] [ "writeBoundary" ]
        ''
          run ${lib.getExe' pkgs.coreutils "install"} -d -m 0700 \
            "$HOME/.config/mcp-gateway" ${lib.escapeShellArg logDirectory}
          if [[ ! -e "$HOME/.config/mcp-gateway/servers.json" ]]; then
            (umask 077; set -o noclobber; [[ -v DRY_RUN ]] || printf '{}\n' > "$HOME/.config/mcp-gateway/servers.json")
          fi
        '';
    launchd.agents.mcp-gateway = {
      enable = true;
      domain = "gui";
      config = {
        ProgramArguments = [ (lib.getExe gateway) ];
        EnvironmentVariables = {
          HOME = config.home.homeDirectory;
          PATH = "${config.home.profileDirectory}/bin:/run/current-system/sw/bin:/usr/bin:/bin:/usr/sbin:/sbin";
        };
        WorkingDirectory = config.home.homeDirectory;
        RunAtLoad = true;
        KeepAlive = true;
        ThrottleInterval = 10;
        ProcessType = "Background";
        Umask = 63;
        StandardOutPath = "${logDirectory}/server.log";
        StandardErrorPath = "${logDirectory}/server.error.log";
      };
    };
  };
}
