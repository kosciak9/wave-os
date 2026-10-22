_:

let
  # Hosts whose node_exporter is scraped over Tailscale MagicDNS.
  nodeHosts = [
    "ahri"
    "jayce"
    "renekton"
    "zilean"
  ];
in
{
  services = {
    victoriametrics = {
      enable = true;
      listenAddress = ":8428";
      retentionPeriod = "12M";
      prometheusConfig = {
        global.scrape_interval = "30s";
        scrape_configs = [
          {
            job_name = "node";
            static_configs = map (host: {
              targets = [ "${host}:9100" ];
              labels = { inherit host; };
            }) nodeHosts;
          }
        ];
      };
      extraOptions = [ "-vmui.customDashboardsPath=${./dashboards}" ];
    };
    victorialogs = {
      enable = true;
      listenAddress = ":9428";
      extraOptions = [
        "-retentionPeriod=90d"
        # OpenWrt's logd forwards syslog over UDP; 514 would need a privileged port.
        "-syslog.listenAddr.udp=:5140"
      ];
    };
  };

  networking.firewall.interfaces = {
    tailscale0.allowedTCPPorts = [
      8428
      9428
    ];
    enp4s0.allowedUDPPorts = [ 5140 ];
  };
}
