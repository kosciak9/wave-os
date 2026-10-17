{
  config,
  lib,
  pkgs,
  ...
}:
{
  systemd.user.services.happier = {
    Unit = {
      Description = "Happier agent daemon";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
    };
    Service = {
      ExecCondition = "${lib.getExe pkgs.happier} auth status --json";
      ExecStart = "${lib.getExe pkgs.happier} daemon start-sync";
      Environment = lib.mapAttrsToList (name: value: "${name}=${value}") {
        inherit (config.home.sessionVariables) HAPPIER_SERVER_URL HAPPIER_WEBAPP_URL;
        HAPPIER_DAEMON_STARTUP_SOURCE = "background-service";
        HAPPIER_DAEMON_SERVICE_LABEL = "happier.service";
        PATH = "${config.home.path}/bin:/run/current-system/sw/bin";
      };
      Restart = "on-failure";
      RestartSec = 10;
      # Stopping the supervisor must not kill independent coding sessions.
      KillMode = "process";
      UMask = "0077";
    };
    Install.WantedBy = [ "default.target" ];
  };
}
