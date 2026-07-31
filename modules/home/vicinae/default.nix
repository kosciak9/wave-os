{
  inputs,
  config,
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
        }
        // lib.optionalAttrs pkgs.stdenv.isLinux {
          icon_theme = "oomox-Kanagawa";
        };
        light = {
          name = "kanagawa";
        };
      };
      launcher_window = {
        compact_mode = {
          enabled = true;
        };
        rounding = 8;
        client_side_decorations = {
          enabled = true;
        };
      };
      close_on_focus_loss = true;
      pop_to_root_on_close = true;
      escape_key_behavior = "close_window";
      providers = {
        "browser-extension" = {
          enabled = false;
        };
        core.entrypoints = {
          about.enabled = false;
          documentation.enabled = false;
          keybind-settings.enabled = false;
          list-extensions.enabled = false;
          manage-fallback.enabled = false;
          oauth-token-store.enabled = false;
          open-config-file.enabled = false;
          open-default-config.enabled = false;
          prune-memory.enabled = false;
          refresh-apps.enabled = false;
          reload-scripts.enabled = false;
          report-bug.enabled = false;
          search-builtin-icons.enabled = false;
          search-emojis.enabled = false;
          show-logs.enabled = false;
          sponsor.enabled = false;
        };
        developer.entrypoints.create.enabled = false;
        font.entrypoints.browse.enabled = false;
        "manage-shortcuts".enabled = false;
        power.entrypoints = {
          hibernate.enabled = false;
          sleep.enabled = true;
          soft-reboot.enabled = false;
          suspend.enabled = false;
        };
        "raycast-compat" = {
          enabled = false;
          entrypoints.store.enabled = false;
        };
        scripts.enabled = false;
        shortcuts.enabled = false;
        snippets.enabled = false;
        system = {
          enabled = false;
          entrypoints = {
            run.enabled = false;
            volume-down.enabled = false;
            volume-up.enabled = false;
          };
        };
        theme = {
          enabled = true;
          entrypoints.set.enabled = false;
        };
        wm.enabled = false;
      };
    };
    systemd = lib.mkIf pkgs.stdenv.isLinux {
      enable = true;
      autoStart = true;
      environment.PATH = "${
        lib.makeBinPath [
          config.home.path
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
          config.home.path
          pkgs.gnupg
          pkgs.oath-toolkit
        ]
      }:/run/current-system/sw/bin:/usr/bin:/bin:/usr/sbin:/sbin";
    };
  };
}
