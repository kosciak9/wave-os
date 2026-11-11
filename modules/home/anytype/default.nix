{
  config,
  lib,
  pkgs,
  ...
}:

{
  home.packages = [ pkgs.anytype-cli ];

  systemd.user.services.anytype = {
    Unit.Description = "Anytype CLI server";
    Service = {
      ExecStart = lib.escapeShellArgs [
        (lib.getExe pkgs.anytype-cli)
        "--no-update-check"
        "serve"
        "--listen-address"
        "127.0.0.1:31012"
      ];
      WorkingDirectory = config.home.homeDirectory;
      Restart = "always";
      RestartSec = 5;
      UMask = "0077";
    };
    Install.WantedBy = [ "default.target" ];
  };
}
