{ lib, pkgs, ... }:

let
  sessionTarget = "wayland-session@hyprland.desktop.target";
in
{
  systemd.user.services.wave-watch = {
    Unit = {
      Description = "Keep the paired InfiniTime watch connected, set and supplied with weather";
      After = [ "wayland-session-waitenv.service" ];
      PartOf = [ sessionTarget ];
    };
    Service = {
      ExecStart = "${lib.getExe pkgs.wave} watch";
      Restart = "always";
      # A missing pairing or BlueZ restart ends the daemon; retry calmly.
      RestartSec = 30;
    };
    Install.WantedBy = [ sessionTarget ];
  };
}
