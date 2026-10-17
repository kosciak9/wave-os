{
  config,
  lib,
  pkgs,
  ...
}:
let
  logDirectory = "${config.home.homeDirectory}/Library/Logs/HappierDaemon";
  startDaemon = pkgs.writeShellScript "happier-daemon" ''
    # Pairing is interactive; an unpaired machine waits for the owner to sign in.
    if ! ${lib.getExe pkgs.happier} auth status --json >/dev/null; then
      exit 0
    fi
    exec ${lib.getExe pkgs.happier} daemon start-sync
  '';
in
{
  home.activation.happierDaemonDirectories = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    ${lib.getExe' pkgs.coreutils "install"} -d -m 0700 -- ${lib.escapeShellArg logDirectory}
  '';

  launchd.agents.happier-daemon = {
    enable = true;
    domain = "gui";
    config = {
      ProgramArguments = [ "${startDaemon}" ];
      EnvironmentVariables = {
        inherit (config.home.sessionVariables) HAPPIER_SERVER_URL HAPPIER_WEBAPP_URL;
        HOME = config.home.homeDirectory;
        PATH = "${config.home.path}/bin:/usr/bin:/bin:/usr/sbin:/sbin";
        HAPPIER_DAEMON_STARTUP_SOURCE = "background-service";
        HAPPIER_DAEMON_SERVICE_LABEL = "org.nix-community.home.happier-daemon";
      };
      RunAtLoad = true;
      KeepAlive.SuccessfulExit = false;
      ThrottleInterval = 10;
      ProcessType = "Background";
      Umask = 63;
      StandardOutPath = "${logDirectory}/daemon.log";
      StandardErrorPath = "${logDirectory}/daemon.error.log";
    };
  };
}
