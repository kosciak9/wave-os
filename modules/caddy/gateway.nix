# The MCP gateway, tailnet-only, on this host's Caddy.
_:

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

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 18111 ];
}
