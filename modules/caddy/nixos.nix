# Public names of the model gateway (tokens.wave.exposed) and the MCP gateway, both tailnet-only.
{
  config,
  pkgs,
  ...
}:

let
  mcpGateway = import ../mcp-gateway/settings.nix;
  # TODO(cutover): settings.nix still names renekton's gateway until clients move here.
  mcpGatewayURL = "https://${config.networking.hostName}.dusky-diatonic.ts.net:18111";
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
      '';
      extraConfig =
        builtins.replaceStrings
          [ "@MCP_GATEWAY_URL@" "@MCP_GATEWAY_ADDR@" ]
          [ mcpGatewayURL mcpGateway.addr ]
          (builtins.readFile ./gateway.Caddyfile);
    };
    # Caddy fetches the certificate of the MCP gateway's tailnet name from tailscaled.
    tailscale.permitCertUid = config.services.caddy.user;
  };

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [
    443
    18111
  ];
}
