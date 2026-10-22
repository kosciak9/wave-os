_:

let
  # Hosts whose node_exporter is scraped over Tailscale MagicDNS.
  nodeHosts = [
    "ahri"
    "jayce"
    "renekton"
    "zilean"
  ];
  # OpenWrt devices from modre-kalhotky, resolved by the router's dnsmasq on the home LAN.
  openwrtHosts = [
    "krtek"
    "myska"
    "zajic"
  ];
  staticTargets =
    domain: port:
    map (host: {
      targets = [ "${host}${domain}:${port}" ];
      labels = { inherit host; };
    });
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
            static_configs = staticTargets "" "9100" nodeHosts;
          }
          {
            job_name = "openwrt";
            static_configs = staticTargets ".lan" "9100" openwrtHosts;
          }
          {
            # The ucode exporter repeats the Lua exporter's node_* metrics; keep only its own.
            job_name = "openwrt-dnsmasq";
            static_configs = staticTargets ".lan" "9101" [ "krtek" ];
            metric_relabel_configs = [
              {
                source_labels = [ "__name__" ];
                regex = "dnsmasq_.+|dhcp_host_info";
                action = "keep";
              }
            ];
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
        # RFC 3164 timestamps carry no zone or year, and the devices log in UTC.
        "-syslog.useLocalTimestamp.udp"
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
