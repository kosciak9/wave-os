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
in
{
  home.packages = [ gateway ];
  home.activation.mcpGatewayDirectories =
    lib.hm.dag.entryBetween [ "reloadSystemd" ] [ "writeBoundary" ]
      ''
        run ${lib.getExe' pkgs.coreutils "install"} -d -m 0700 "$HOME/.config/mcp-gateway"
        if [[ ! -e "$HOME/.config/mcp-gateway/servers.json" ]]; then
          (umask 077; set -o noclobber; [[ -v DRY_RUN ]] || printf '{}\n' > "$HOME/.config/mcp-gateway/servers.json")
        fi
      '';
  systemd.user.services.mcp-gateway = {
    Unit = {
      Description = "MCP gateway";
      X-Restart-Triggers = [ (toString gateway) ];
    };
    Service = {
      ExecStart = lib.getExe gateway;
      # Stdio servers in servers.json start from here (sh, npx, pass).
      Environment = [
        "PATH=${config.home.profileDirectory}/bin:/run/current-system/sw/bin:/usr/bin:/bin"
      ];
      WorkingDirectory = config.home.homeDirectory;
      Restart = "always";
      RestartSec = 10;
      UMask = "0077";
    };
    Install.WantedBy = [ "default.target" ];
  };
}
