{
  inputs,
  lib,
  pkgs,
  ...
}:

let
  passExtension =
    inputs.vicinae-extensions.packages.${pkgs.stdenv.hostPlatform.system}.pass.overrideAttrs
      (oldAttrs: {
        patches = (oldAttrs.patches or [ ]) ++ [ ./pass-gpg-agent.patch ];
      });
in
{
  imports = [ inputs.vicinae.homeManagerModules.default ];

  programs.vicinae = {
    enable = true;
    extensions = [ passExtension ];
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
      environment.PATH = "${
        lib.makeBinPath [
          pkgs.gnupg
          pkgs.oath-toolkit
        ]
      }:/run/current-system/sw/bin:/usr/bin:/bin:/usr/sbin:/sbin";
    };
    launchd = lib.mkIf pkgs.stdenv.isDarwin {
      enable = true;
      autoStart = true;
      environment.PATH = "${
        lib.makeBinPath [
          pkgs.gnupg
          pkgs.oath-toolkit
        ]
      }:/run/current-system/sw/bin:/usr/bin:/bin:/usr/sbin:/sbin";
    };
  };
}
