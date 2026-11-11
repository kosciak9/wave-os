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
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  logDirectory = "${config.home.homeDirectory}/Library/Logs/MCPGateway";
  # Stdio servers in servers.json start from here (sh, npx, pass).
  path = "${config.home.profileDirectory}/bin:/run/current-system/sw/bin:/usr/bin:/bin:/usr/sbin:/sbin";
in
{
  config = lib.mkMerge [
    {
      home.packages = [ gateway ];
      home.activation.mcpGatewayDirectories =
        lib.hm.dag.entryBetween
          [ (if isDarwin then "setupLaunchAgents" else "reloadSystemd") ]
          [ "writeBoundary" ]
          ''
            run ${lib.getExe' pkgs.coreutils "install"} -d -m 0700 \
              "$HOME/.config/mcp-gateway" ${lib.optionalString isDarwin (lib.escapeShellArg logDirectory)}
            if [[ ! -e "$HOME/.config/mcp-gateway/servers.json" ]]; then
              (umask 077; set -o noclobber; [[ -v DRY_RUN ]] || printf '{}\n' > "$HOME/.config/mcp-gateway/servers.json")
            fi
          '';
    }
    (lib.mkIf isDarwin {
      launchd.agents.mcp-gateway = {
        enable = true;
        domain = "gui";
        config = {
          ProgramArguments = [ (lib.getExe gateway) ];
          EnvironmentVariables = {
            HOME = config.home.homeDirectory;
            PATH = path;
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
    })
    (lib.mkIf (!isDarwin) {
      systemd.user.services.mcp-gateway = {
        Unit = {
          Description = "MCP gateway";
          X-Restart-Triggers = [ (toString gateway) ];
        };
        Service = {
          ExecStart = lib.getExe gateway;
          Environment = [ "PATH=${path}" ];
          WorkingDirectory = config.home.homeDirectory;
          Restart = "always";
          RestartSec = 10;
          UMask = "0077";
        };
        Install.WantedBy = [ "default.target" ];
      };
    })
  ];
}
