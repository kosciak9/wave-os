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
  server2 = pkgs.callPackage ../../../packages/opencode2-server.nix {
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

  systemd.user.services.opencode2 = {
    Unit.Description = "OpenCode v2 headless server";
    Service = {
      Type = "simple";
      ExecStart = lib.getExe server2;
      Restart = "always";
      RestartSec = 5;
      TimeoutStopSec = 20;
    };
    Install.WantedBy = [ "default.target" ];
  };
}
