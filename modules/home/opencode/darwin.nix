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
  launchd.agents.opencode = {
    enable = true;
    domain = "gui";
    config = {
      ProgramArguments = [ (lib.getExe server) ];
      RunAtLoad = true;
      KeepAlive = true;
      ProcessType = "Background";
      ThrottleInterval = 5;
    };
  };
}
