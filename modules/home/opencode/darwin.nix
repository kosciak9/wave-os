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
  configGeneration = lib.concatStringsSep ":" [
    (toString config.xdg.configFile."opencode/opencode.jsonc".source)
    (toString config.xdg.configFile."opencode/plugin".source)
    (toString config.xdg.configFile."opencode/tui.jsonc".source)
  ];
in
{
  launchd.agents.opencode = {
    enable = true;
    domain = "gui";
    config = {
      EnvironmentVariables.OPENCODE_CONFIG_GENERATION = configGeneration;
      ProgramArguments = [ (lib.getExe server) ];
      RunAtLoad = true;
      KeepAlive = true;
      ProcessType = "Background";
      ThrottleInterval = 5;
    };
  };
}
