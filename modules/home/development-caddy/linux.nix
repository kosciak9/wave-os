{
  lib,
  pkgs,
  ...
}:

let
  development-caddy = pkgs.callPackage ../../../packages/development-caddy.nix { };
in
{
  home.packages = [ development-caddy ];

  systemd.user.services.development-caddy = {
    Unit.Description = "Development Caddy dashboard";
    Service = {
      Type = "simple";
      ExecStart = lib.concatStringsSep " " [
        (lib.getExe development-caddy)
        "--bind 127.0.0.1"
        "--port 11190"
        "--caddy-admin-url http://127.0.0.1:2019"
        "--caddy-server https"
        "--state-dir %S/development-caddy"
      ];
      StateDirectory = "development-caddy";
      StateDirectoryMode = "0700";
      Restart = "on-failure";
      RestartSec = 5;
      UMask = "0077";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = "read-only";
      ReadWritePaths = [ "%S/development-caddy" ];
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
      ];
    };
    Install.WantedBy = [ "default.target" ];
  };
}
