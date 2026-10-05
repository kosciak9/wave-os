{ inputs, pkgs, ... }:
{
  home.packages = [ inputs.herdr-gpui.packages.${pkgs.stdenv.hostPlatform.system}.default ];

  # Settings saves replace this symlink; edit preferences here instead of in the GUI.
  xdg.configFile."herdr/config-gpui.local.toml".source =
    (pkgs.formats.toml { }).generate "herdr-gpui-settings"
      {
        show_agents = true;
        theme = "light:kanagawa,dark:kanagawa";
        layout = {
          mode = "superset";
          sidebar_gap = 8.0;
        };
        terminal.family = "Overpass Mono";
        sidebar.family = "Overpass";
        tabs.family = "Overpass";
        ui.family = "Overpass";
      };
}
