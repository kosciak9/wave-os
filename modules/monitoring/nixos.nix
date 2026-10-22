_:

{
  services = {
    prometheus.exporters.node.enable = true;
    journald.upload = {
      enable = true;
      settings.Upload.URL = "http://zilean:9428/insert/journald";
    };
  };

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 9100 ];
}
