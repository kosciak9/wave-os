_:

{
  services = {
    prometheus.exporters.node.enable = true;
    journald.upload = {
      enable = true;
      settings.Upload.URL = "http://zilean:9428/insert/journald";
    };
  };

  # A network drop mid-upload leaves the uploader blocked in curl until the
  # unit's watchdog fires; the default SIGABRT then leaves a core dump each
  # time. It cannot exit cleanly there (SIGTERM is ignored while blocked), and
  # NetworkTimeoutSec would cap whole requests, so a long catch-up would
  # retry forever without saving its cursor.
  systemd.services.systemd-journal-upload.serviceConfig.WatchdogSignal = "SIGKILL";

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 9100 ];
}
