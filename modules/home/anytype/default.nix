{
  config,
  lib,
  pkgs,
  ...
}:

let
  homeDirectory = config.home.homeDirectory;
  logDirectory = "${homeDirectory}/.anytype/logs";
  install = lib.getExe' pkgs.coreutils "install";
in
{
  home.packages = [ pkgs.anytype-cli ];

  home.activation.anytypeLogDirectory = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    ${install} -d -m 0700 -- ${lib.escapeShellArg logDirectory}
  '';

  launchd.agents."io.anytype.cli" = {
    enable = true;
    domain = "gui";
    config = {
      ProgramArguments = [
        (lib.getExe pkgs.anytype-cli)
        "--no-update-check"
        "serve"
        "--listen-address"
        "127.0.0.1:31012"
      ];
      EnvironmentVariables = {
        HOME = homeDirectory;
        PATH = "/usr/bin:/bin:/usr/sbin:/sbin";
      };
      WorkingDirectory = homeDirectory;
      RunAtLoad = true;
      KeepAlive = true;
      ProcessType = "Background";
      ThrottleInterval = 5;
      Umask = 63;
      StandardOutPath = "${logDirectory}/anytype.out.log";
      StandardErrorPath = "${logDirectory}/anytype.err.log";
    };
  };
}
