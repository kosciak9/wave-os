# This host's tailnet-only name, <host>.wave.exposed, serving T3 Code through Caddy with
# Cloudflare DNS-01 certificates. Hosts add further sites through services.caddy.extraConfig.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  name = "${config.networking.hostName}.wave.exposed";
in
{
  sops = {
    secrets."cloudflare/dns-api-token" = { };
    templates."caddy-cloudflare.env" = {
      content = "CLOUDFLARE_API_TOKEN=${config.sops.placeholder."cloudflare/dns-api-token"}";
      restartUnits = [ "caddy.service" ];
    };
  };

  services.caddy = {
    enable = true;
    package = pkgs.caddy.withPlugins {
      plugins = [ "github.com/caddy-dns/cloudflare@v0.2.4" ];
      hash = "sha256-tubXIDCJnO2mvdnPlZclwDhNGaeeYLSt7lnni3+pXDo=";
    };
    environmentFile = config.sops.templates."caddy-cloudflare.env".path;
    # Off: any local user (Alfred, agents, containers given loopback ports) could otherwise
    # rewrite the routes. A new config takes a restart instead of a reload.
    enableReload = false;
    globalConfig = ''
      admin off
      auto_https disable_redirects
      skip_install_trust
      # A client whose Wi-Fi drops for about a minute stalls its upload or response; past the
      # default 1m idle limits Caddy aborts the request (logged as 499/504). Both limits reset
      # on every read or write, so 3m only lets such stalls through.
      servers {
        timeouts {
          read_body_idle 3m
          write_idle 3m
        }
      }
    '';
    extraConfig = ''
      https://${name} {
        tls {
          dns cloudflare {env.CLOUDFLARE_API_TOKEN}
          resolvers 1.1.1.1
        }
        @outside not remote_ip 127.0.0.1 ::1 100.64.0.0/10 fd7a:115c:a1e0::/48
        respond @outside 403
        reverse_proxy 127.0.0.1:3773
      }
    '';
  };

  # Local clients (agents, Alfred) reach this host's sites over loopback, independent of its
  # tailnet address.
  networking.hosts."127.0.0.1" = [ name ];

  # Through Caddy, so a certificate that cannot be renewed fails the check too.
  wave.health.checks.t3code = ''
    ${lib.getExe pkgs.curl} -q -fsS --max-time 3 https://${name}/.well-known/t3/environment >/dev/null
  '';

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 443 ];
}
