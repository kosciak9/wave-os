{ lib, pkgs, ... }:

let
  cuaDriver = pkgs.callPackage ../../../packages/cua-driver.nix { };
  sessionTarget = "wayland-session@hyprland.desktop.target";
in
{
  home.packages = [ cuaDriver ];

  systemd.user.services.cua-driver = {
    Unit = {
      Description = "Cua Driver local desktop daemon";
      After = [ "wayland-session-waitenv.service" ];
      PartOf = [ sessionTarget ];
      ConditionEnvironment = "WAYLAND_DISPLAY";
    };
    Service = {
      Environment = [ "CUA_DRIVER_RS_ENABLE_WAYLAND=1" ];
      ExecStart = "${lib.getExe cuaDriver} serve --permission-mode standard";
      Restart = "on-failure";
      RestartSec = 2;
      UMask = "0077";
      NoNewPrivileges = true;
    };
    Install.WantedBy = [ sessionTarget ];
  };
}
