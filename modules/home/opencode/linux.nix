{
  config,
  lib,
  pkgs,
  ...
}:

let
  server = pkgs.callPackage ../../../packages/opencode-server.nix {
    homeDirectory = config.home.homeDirectory;
    profileDirectory = config.home.profileDirectory;
  };
in
{
  systemd.user.services.opencode = {
    Unit.Description = "OpenCode headless server";
    Service = {
      Type = "simple";
      ExecStart = lib.getExe server;
      Restart = "always";
      RestartSec = 5;
      TimeoutStopSec = 20;
    };
    Install.WantedBy = [ "default.target" ];
  };
}
