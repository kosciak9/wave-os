{
  config,
  lib,
  pkgs,
  ...
}:

{
  home.packages = [ pkgs.pr-cockpit ];
  xdg.mimeApps.defaultApplications."x-scheme-handler/prcockpit" = [ "app.pr-cockpit.desktop" ];

  systemd.user.services.pr-cockpit = {
    Unit = {
      Description = "PR Cockpit local server";
      After = [ "network-online.target" ];
    };
    Service = {
      Type = "simple";
      ExecStart = "${lib.getExe' pkgs.pr-cockpit "pr-cockpit-app"} --server-only";
      WorkingDirectory = "${pkgs.pr-cockpit}/share/pr-cockpit";
      Environment = [
        "COCKPIT_SUPERVISOR=systemd-user"
        "COCKPIT_DATA_DIR=${config.xdg.dataHome}/pr-cockpit"
        "XDG_CONFIG_HOME=${config.xdg.configHome}"
        "XDG_DATA_HOME=${config.xdg.dataHome}"
        "XDG_STATE_HOME=${config.xdg.stateHome}"
        "PATH=${config.home.profileDirectory}/bin:/etc/profiles/per-user/${config.home.username}/bin:/run/current-system/sw/bin"
      ];
      Restart = "on-failure";
      RestartSec = 3;
      UMask = "0077";
    };
    Install.WantedBy = [ "default.target" ];
  };
}
