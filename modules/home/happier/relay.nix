{
  config,
  lib,
  pkgs,
  ...
}:
let
  stateDirectory = "${config.home.homeDirectory}/Library/Application Support/HappierRelay";
  logDirectory = "${config.home.homeDirectory}/Library/Logs/HappierRelay";
  relayUrl = config.home.sessionVariables.HAPPIER_SERVER_URL;
in
{
  home.activation.happierRelayDirectories = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    ${lib.getExe' pkgs.coreutils "install"} -d -m 0700 -- \
      ${lib.escapeShellArg stateDirectory} ${lib.escapeShellArg logDirectory}
  '';

  launchd.agents.happier-relay = {
    enable = true;
    domain = "gui";
    config = {
      ProgramArguments = [ (lib.getExe pkgs.happier-server) ];
      EnvironmentVariables = {
        HOME = config.home.homeDirectory;
        NODE_ENV = "production";
        PORT = "3005";
        HAPPIER_SERVER_HOST = "127.0.0.1";
        HAPPIER_SERVER_FLAVOR = "light";
        HAPPIER_DB_PROVIDER = "sqlite";
        # Prisma's native SQLite driver needs literal spaces in the file path.
        DATABASE_URL = "file:${stateDirectory}/happier-server-light.sqlite";
        HAPPIER_FILES_BACKEND = "local";
        # Light mode persists its generated master secret alongside the database.
        HAPPIER_SERVER_LIGHT_DATA_DIR = stateDirectory;
        HAPPIER_PUBLIC_SERVER_URL = relayUrl;
        HAPPIER_WEBAPP_URL = relayUrl;
        PUBLIC_URL = relayUrl;
        HAPPIER_SERVER_TRUST_PROXY = "1";
        HAPPIER_TAILSCALE_INFER_PUBLIC_URL = "0";
        HAPPIER_FEATURE_BUG_REPORTS__ENABLED = "0";
        HAPPIER_FEATURE_VOICE__ENABLED = "0";
        METRICS_ENABLED = "false";
      };
      WorkingDirectory = stateDirectory;
      RunAtLoad = true;
      KeepAlive = true;
      ThrottleInterval = 10;
      ProcessType = "Background";
      Umask = 63;
      StandardOutPath = "${logDirectory}/server.log";
      StandardErrorPath = "${logDirectory}/server.error.log";
    };
  };
}
