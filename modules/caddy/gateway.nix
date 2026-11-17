# The model gateway (tokens.wave.exposed) and the MCP gateway, both tailnet-only, on this host's
# Caddy.
{
  lib,
  pkgs,
  ...
}:

let
  mcpGateway = import ../mcp-gateway/settings.nix;
in
{
  imports = [ ./nixos.nix ];

  services.caddy.extraConfig =
    builtins.replaceStrings
      [ "@MCP_GATEWAY_URL@" "@MCP_GATEWAY_ADDR@" ]
      [ mcpGateway.baseURL mcpGateway.addr ]
      (builtins.readFile ./gateway.Caddyfile);

  # Local agents keep their tokens while the host's tailnet address changes.
  networking.hosts."127.0.0.1" = [ "tokens.wave.exposed" ];

  # Through the site name, so a lost TLS policy or a certificate that Caddy cannot renew fails
  # the check instead of the gateway itself; pinned to loopback, so it checks this host's Caddy.
  wave.health.checks.tokens = ''
    test "$(${lib.getExe pkgs.curl} --silent --output /dev/null --write-out '%{http_code}' --max-time 5 \
      --resolve tokens.wave.exposed:443:127.0.0.1 https://tokens.wave.exposed/v1/models)" = 401
  '';

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 18111 ];
}
