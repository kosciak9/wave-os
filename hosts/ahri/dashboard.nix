{
  config,
  lib,
  pkgs,
  ...
}:

let
  domain = "wave.exposed";
  dashboardPort = 4000;
  caddyAdmin = "localhost:2019";
  # T3 Code servers whose open threads the dashboard lists, each read with its own read-only token.
  t3Servers = [
    "jayce"
    "renekton"
  ];
  t3Secret = server: "t3/${server}-token";
  caddy = pkgs.caddy.withPlugins {
    plugins = [ "github.com/caddy-dns/cloudflare@v0.2.4" ];
    hash = "sha256-xRJ5evsAJ2akg47j3Bt6YDXJOgX88B/rKNP50KSVyNY=";
  };
in
{
  sops = {
    secrets = {
      "cloudflare/dns-api-token" = { };
      "cliproxyapi/quota-key".restartUnits = [ "wave-dashboard.service" ];
      "cliproxyapi/base-url".restartUnits = [ "wave-dashboard.service" ];
    }
    // lib.genAttrs (map t3Secret t3Servers) (_: {
      restartUnits = [ "wave-dashboard.service" ];
    });
    templates."caddy-cloudflare.env" = {
      content = "CLOUDFLARE_API_TOKEN=${config.sops.placeholder."cloudflare/dns-api-token"}";
      restartUnits = [ "caddy.service" ];
    };
  };

  # The dashboard replaces this configuration with one that also routes registered apps;
  # this one keeps the dashboard reachable until it does. It only does so where
  # CADDY_ADMIN_URL below names this Caddy as the instance it owns.
  services.caddy = {
    enable = true;
    package = caddy;
    environmentFile = config.sops.templates."caddy-cloudflare.env".path;
    globalConfig = ''
      admin ${caddyAdmin}
      auto_https disable_redirects
      acme_dns cloudflare {env.CLOUDFLARE_API_TOKEN}
    '';
    virtualHosts.${domain}.extraConfig = ''
      reverse_proxy 127.0.0.1:${toString dashboardPort}
    '';
  };

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 443 ];

  systemd.services.wave-dashboard = {
    description = "Wave dashboard";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [
      "network-online.target"
      "tailscaled.service"
      "caddy.service"
    ];
    path = [ config.services.tailscale.package ];
    environment = {
      PORT = toString dashboardPort;
      CADDY_ADMIN_URL = "http://${caddyAdmin}";
      T3_SERVERS = lib.concatMapStringsSep "," (
        server: "${server}=https://${server}.dusky-diatonic.ts.net:18443"
      ) t3Servers;
      RELEASE_DISTRIBUTION = "none";
      # Distribution is off, so the cookie never authenticates anything.
      RELEASE_COOKIE = "wave-dashboard";
      RELEASE_TMP = "/run/wave-dashboard";
    };
    serviceConfig = {
      ExecStart = "${lib.getExe pkgs.wave-dashboard} start";
      # Decrypted secrets are root's; credentials hand them to the dynamic user.
      LoadCredential = [
        "quota-key:${config.sops.secrets."cliproxyapi/quota-key".path}"
        "quota-url:${config.sops.secrets."cliproxyapi/base-url".path}"
      ]
      ++ map (server: "t3-${server}:${config.sops.secrets.${t3Secret server}.path}") t3Servers;
      DynamicUser = true;
      StateDirectory = "wave-dashboard";
      StateDirectoryMode = "0700";
      RuntimeDirectory = "wave-dashboard";
      Restart = "on-failure";
      RestartSec = 5;
      UMask = "0077";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
      ];
    };
  };

  wave.health.checks = {
    caddy = ''
      ${lib.getExe pkgs.curl} -q -sSf --noproxy '*' --max-time 3 --output /dev/null http://${caddyAdmin}/config/
    '';
    wave-dashboard = ''
      ${lib.getExe pkgs.curl} -q -sSf --noproxy '*' --max-time 3 --output /dev/null http://127.0.0.1:${toString dashboardPort}/healthz
    '';
  };
}
