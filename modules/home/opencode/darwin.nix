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
  configGeneration = lib.concatStringsSep ":" [
    (toString config.xdg.configFile."opencode/opencode.jsonc".source)
    (toString config.xdg.configFile."opencode/plugin".source)
    (toString config.xdg.configFile."opencode/tui.jsonc".source)
  ];
  configGeneration2 = toString config.home.file.".config/opencode-v2/opencode".source;
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

  launchd.agents.opencode2 = {
    enable = true;
    domain = "gui";
    config = {
      EnvironmentVariables.OPENCODE_CONFIG_GENERATION = configGeneration2;
      ProgramArguments = [ (lib.getExe server2) ];
      RunAtLoad = true;
      KeepAlive = true;
      ProcessType = "Background";
      ThrottleInterval = 5;
    };
  };
}
