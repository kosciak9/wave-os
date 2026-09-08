{
  config,
  lib,
  pkgs,
  ...
}:

let
  development-caddy = pkgs.callPackage ../../../packages/development-caddy.nix { };
in
{
  home.packages = [ development-caddy ];

  launchd.agents.development-caddy = {
    enable = true;
    domain = "gui";
    config = {
      ProgramArguments = [
        (lib.getExe development-caddy)
        "--bind"
        "127.0.0.1"
        "--port"
        "11190"
        "--caddy-admin-url"
        "http://127.0.0.1:2019"
        "--caddy-server"
        "https"
        "--state-dir"
        "${config.xdg.stateHome}/development-caddy"
      ];
      RunAtLoad = true;
      KeepAlive = true;
      ProcessType = "Background";
      ThrottleInterval = 5;
    };
  };
}
