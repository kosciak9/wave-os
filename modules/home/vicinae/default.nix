{
  inputs,
  lib,
  pkgs,
  ...
}:

{
  imports = [ inputs.vicinae.homeManagerModules.default ];

  programs.vicinae = {
    enable = true;
    extensions = [ ];
    settings = {
      font = {
        normal = {
          family = "Overpass Nerd Font";
          size = 12;
        };
        rendering = "native";
      };
      theme = {
        dark = {
          name = "kanagawa";
        };
        light = {
          name = "kanagawa";
        };
      };
      launcher_window = {
        compact_mode = {
          enabled = true;
        };
      };
    };
    systemd = lib.mkIf pkgs.stdenv.isLinux {
      enable = true;
      autoStart = true;
    };
    launchd = lib.mkIf pkgs.stdenv.isDarwin {
      enable = true;
      autoStart = true;
    };
  };
}
