# Tailnet-only public names: the model gateway (tokens.wave.exposed), the MCP gateway and T3 Code.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  mcpGateway = import ../mcp-gateway/settings.nix;
in
{
  sops = {
    secrets."cloudflare/dns-api-token" = { };
    templates."caddy-cloudflare.env" = {
      content = "CLOUDFLARE_API_TOKEN=${config.sops.placeholder."cloudflare/dns-api-token"}";
      restartUnits = [ "caddy.service" ];
    };
  };

  services = {
    caddy = {
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
      extraConfig =
        builtins.replaceStrings
          [ "@MCP_GATEWAY_URL@" "@MCP_GATEWAY_ADDR@" ]
          [ mcpGateway.baseURL mcpGateway.addr ]
          (builtins.readFile ./gateway.Caddyfile);
    };
    # Caddy fetches the certificate of the MCP gateway's Tailscale name from tailscaled.
    tailscale.permitCertUid = config.services.caddy.user;
  };

  # Local clients (agents, Alfred) reach these sites over loopback, so they keep working while
  # the host's tailnet address changes.
  networking.hosts."127.0.0.1" = [
    "tokens.wave.exposed"
    "zilean.wave.exposed"
  ];

  # Through the site name, so a lost TLS policy or a certificate that Caddy cannot renew fails
  # the check instead of the gateway itself; pinned to loopback, so it checks this host's Caddy.
  wave.health.checks.tokens = ''
    test "$(${lib.getExe pkgs.curl} --silent --output /dev/null --write-out '%{http_code}' --max-time 5 \
      --resolve tokens.wave.exposed:443:127.0.0.1 https://tokens.wave.exposed/v1/models)" = 401
  '';
  wave.health.checks.t3code = ''
    ${lib.getExe pkgs.curl} -q -fsS --max-time 3 \
      https://zilean.wave.exposed/.well-known/t3/environment >/dev/null
  '';

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [
    443
    18111
  ];
}
