{ lib, pkgs, ... }:
{
  # The FoxPilot add-on is installed from addons.mozilla.org; it pairs with this server over loopback.
  programs.agents.mcpServers.foxpilot = [
    (lib.getExe (pkgs.callPackage ../../../packages/foxpilot-mcp.nix { }))
  ];
}
