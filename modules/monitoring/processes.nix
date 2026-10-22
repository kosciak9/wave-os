_:

{
  services.prometheus.exporters.process = {
    enable = true;
    # One group per executable name, like btop's process list.
    settings.process_names = [
      {
        name = "{{.Comm}}";
        cmdline = [ ".+" ];
      }
    ];
    extraFlags = [ "-threads=false" ];
  };

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 9256 ];
}
