{ lib, pkgs, ... }:

{
  # pf admits inbound traffic only from Tailscale, so the exporter can listen on all interfaces.
  launchd.daemons.node-exporter.serviceConfig = {
    ProgramArguments = [
      (lib.getExe pkgs.prometheus-node-exporter)
      "--web.listen-address=:9100"
    ];
    RunAtLoad = true;
    KeepAlive = true;
    ProcessType = "Background";
    UserName = "nobody";
    GroupName = "nobody";
  };
}
