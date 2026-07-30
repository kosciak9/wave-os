{
  lib,
  pkgs,
  inputs,
  kanagawa-kvantum,
  ...
}:

let
  wallpaper = "/home/kosciak/.config/secrets/wallpapers/kanagawa-black-centered.png";
  sessionTarget = "wayland-session@hyprland.desktop.target";
  geocluePackage = pkgs.geoclue2-with-demo-agent;
  backlightDim = pkgs.writeShellApplication {
    name = "wave-backlight-dim";
    runtimeInputs = with pkgs; [
      brightnessctl
      coreutils
      hyprland
      jq
    ];
    text = builtins.readFile ./scripts/backlight-dim.sh;
  };
  lidHandler = pkgs.writeShellApplication {
    name = "wave-lid-handler";
    runtimeInputs = with pkgs; [
      coreutils
      hyprland
      jq
      quickshell
      systemd
    ];
    text = builtins.readFile ./scripts/lid-handler.sh;
  };
  nightLight = pkgs.writeShellApplication {
    name = "wave-night-light";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      hyprland
      sunwait
    ];
    text =
      builtins.replaceStrings
        [ "@where-am-i@" ]
        [ "${geocluePackage}/libexec/geoclue-2.0/demos/where-am-i" ]
        (builtins.readFile ./scripts/night-light.sh);
  };
  lockStatus = pkgs.writeShellApplication {
    name = "wave-lock-status";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      capacity="AC"
      for battery in /sys/class/power_supply/BAT*; do
        if [[ -r "$battery/capacity" ]]; then
          read -r capacity < "$battery/capacity"
          break
        fi
      done

      charging=""
      for supply in /sys/class/power_supply/*; do
        [[ -r "$supply/type" && -r "$supply/online" ]] || continue
        read -r type < "$supply/type"
        case "$type" in
          Mains|USB|USB_C|Wireless)
            read -r online < "$supply/online"
            if [[ $online == 1 ]]; then
              charging=" ⚡"
              break
            fi
            ;;
        esac
      done

      if [[ $capacity =~ ^[0-9]+$ ]]; then
        printf '%s\n%s%%%s\n' "$(hostname)" "$capacity" "$charging"
      else
        printf '%s\n%s%s\n' "$(hostname)" "$capacity" "$charging"
      fi
    '';
  };
in
{
  imports = [
    ../../modules/home/cli
    ../../modules/home/devenv
    ../../modules/home/ghostty
    ../../modules/home/git.nix
    ../../modules/home/neovim
    ../../modules/home/opencode
    ../../modules/home/opencode/linux.nix
    ../../modules/home/starship
    ../../modules/home/vicinae
    ../../modules/home/zoxide
    ../../modules/home/zen-browser
    ../../modules/home/zsh
    ../../modules/home/zsh/linux.nix
  ];

  home = {
    username = "kosciak";
    homeDirectory = "/home/kosciak";
    stateVersion = "26.05";
    sessionPath = [
      "$HOME/.local/share/android-sdk/platform-tools"
      "$HOME/.local/share/android-sdk/cmdline-tools/latest/bin"
      "$HOME/.cargo/bin"
      "$HOME/.local/bin"
    ];
    sessionVariables = {
      ANDROID_HOME = "$HOME/.local/share/android-sdk";
      GTK_USE_PORTAL = "1";
      OPENCODE_ATTACH_TARGET = "localhost:51199";
      QT_QPA_PLATFORM = "wayland";
      _JAVA_AWT_WM_NONREPARENTING = "1";
      QT_STYLE_OVERRIDE = "kvantum";
    };
    packages = with pkgs; [
      brightnessctl
      chromium
      fd
      hyprsunset
      hyprshot
      (iosevka-bin.override { variant = "SGr-IosevkaTerm"; })
      jq
      kanagawa-kvantum
      karla
      kdePackages.qtstyleplugin-kvantum
      nerd-fonts.iosevka
      nerd-fonts.overpass
      nerd-fonts.symbols-only
      neovide
      nodejs
      noto-fonts
      noto-fonts-color-emoji
      obsidian
      playerctl
      pulseaudio
      pwvucontrol
      ripgrep
      trash-cli
      wl-clipboard
      inputs.zen-browser.packages.${pkgs.stdenv.hostPlatform.system}.default
      worktrunk
    ];
  };

  fonts.fontconfig.enable = true;

  home.pointerCursor = {
    enable = true;
    package = pkgs.adwaita-icon-theme;
    name = "Adwaita";
    size = 24;
    gtk.enable = true;
    x11.enable = true;
  };

  programs = {
    home-manager.enable = true;
    zen-browser = {
      enable = true;
      package = inputs.zen-browser.packages.${pkgs.stdenv.hostPlatform.system}.default;
      profileName = "wave";
    };
    quickshell = {
      enable = true;
      activeConfig = "wave";
      configs.wave = ./desktop/quickshell;
      systemd = {
        enable = true;
        target = sessionTarget;
      };
    };
    password-store.enable = true;
    hyprlock = {
      enable = true;
      settings = {
        general.hide_cursor = true;
        auth.fingerprint.enabled = true;
        animations = {
          enabled = true;
          bezier = "snappy, 0.16, 1, 0.3, 1";
          animation = "global, 1, 2, snappy";
        };
        background = [
          {
            monitor = "";
            path = "screenshot";
            color = "rgb(22, 22, 29)";
            blur_size = 8;
            blur_passes = 2;
          }
        ];
        input-field = [
          {
            monitor = "";
            size = "250, 50";
            outline_thickness = 2;
            rounding = 2;
            outer_color = "rgb(126, 156, 216)";
            inner_color = "rgb(31, 31, 40)";
            font_color = "rgb(220, 215, 186)";
            font_family = "OverpassM Nerd Font Mono";
            fade_on_empty = true;
            placeholder_text = "";
            fail_color = "rgb(195, 64, 67)";
            fail_text = "";
            position = "0, 30";
            halign = "center";
            valign = "bottom";
          }
        ];
        label = [
          {
            monitor = "";
            text = ''cmd[update:1000] date +"%H"'';
            color = "rgb(220, 215, 186)";
            font_size = 180;
            font_family = "OverpassM Nerd Font Mono Bold";
            position = "38%, 116";
            halign = "left";
            valign = "center";
            shadow_passes = 1;
            shadow_size = 5;
            shadow_color = "rgb(0, 0, 0)";
            shadow_boost = 1.5;
          }
          {
            monitor = "";
            text = ''cmd[update:1000] date +"%M"'';
            color = "rgb(220, 215, 186)";
            font_size = 180;
            font_family = "OverpassM Nerd Font Mono Bold";
            position = "38%, -116";
            halign = "left";
            valign = "center";
            shadow_passes = 1;
            shadow_size = 5;
            shadow_color = "rgb(0, 0, 0)";
            shadow_boost = 1.5;
          }
          {
            monitor = "";
            text = ''cmd[update:60000] printf "%s\n%s" "$(date +%a)" "$(date +'%d %b')"'';
            text_align = "left";
            color = "rgb(149, 127, 184)";
            font_size = 28;
            font_family = "OverpassM Nerd Font Mono";
            position = "52%, 116";
            halign = "left";
            valign = "center";
            shadow_passes = 1;
            shadow_size = 3;
            shadow_color = "rgb(0, 0, 0)";
            shadow_boost = 1.5;
          }
          {
            monitor = "";
            text = "cmd[update:30000] ${lib.getExe lockStatus}";
            text_align = "left";
            color = "rgb(149, 127, 184)";
            font_size = 28;
            font_family = "OverpassM Nerd Font Mono";
            position = "52%, -116";
            halign = "left";
            valign = "center";
            shadow_passes = 1;
            shadow_size = 3;
            shadow_color = "rgb(0, 0, 0)";
            shadow_boost = 1.5;
          }
        ];
      };
    };
  };

  services = {
    flatpak = {
      enable = true;
      remotes = [
        {
          name = "flathub";
          location = "https://dl.flathub.org/repo/flathub.flatpakrepo";
        }
      ];
      packages = [
        "com.slack.Slack"
        "org.telegram.desktop"
      ];
      overrides = {
        global.Context.filesystems = [
          "~/.themes:ro"
          "~/.icons:ro"
          "xdg-config/gtk-4.0:ro"
        ];
      };
      update.auto = {
        enable = true;
        onCalendar = "daily";
      };
    };
    hypridle = {
      enable = true;
      settings = {
        general = {
          lock_cmd = "pidof hyprlock || hyprlock";
          before_sleep_cmd = "systemctl --user stop wave-backlight-dim.service; loginctl lock-session";
          after_sleep_cmd = "hyprctl dispatch 'hl.dsp.dpms({ action = \"enable\" })'";
        };
        listener = [
          {
            timeout = 240;
            on-timeout = "systemctl --user start wave-backlight-dim.service";
            on-resume = "systemctl --user stop wave-backlight-dim.service";
          }
          {
            timeout = 300;
            on-timeout = "loginctl lock-session";
          }
          {
            timeout = 600;
            on-timeout = "hyprctl dispatch 'hl.dsp.dpms({ action = \"disable\" })'";
            on-resume = "hyprctl dispatch 'hl.dsp.dpms({ action = \"enable\" })'";
          }
        ];
      };
    };
    hyprpaper = {
      enable = true;
      settings = {
        ipc = "on";
        splash = false;
        wallpaper = [
          {
            monitor = "*";
            path = "${wallpaper}";
          }
        ];
      };
    };
  };

  xdg = {
    enable = true;
    userDirs = {
      enable = true;
      createDirectories = true;
      desktop = "$HOME";
      download = "$HOME/downloads";
      templates = "$HOME";
      publicShare = "$HOME/public";
      documents = "$HOME/documents";
      music = "$HOME/media";
      pictures = "$HOME/media";
      videos = "$HOME/media";
    };
    configFile = {
      "Kvantum/Kanagawa".source = "${kanagawa-kvantum}/share/Kvantum/Kanagawa";
      "Kvantum/kvantum.kvconfig".text = ''
        [General]
        theme=Kanagawa
      '';
    };
  };

  gtk = {
    enable = true;
    theme = {
      name = "Kanagawa-B-LB";
      package = pkgs.kanagawa-gtk-theme;
    };
    iconTheme = {
      name = "Kanagawa";
      package = pkgs.kanagawa-icon-theme;
    };
    gtk3.extraConfig.gtk-application-prefer-dark-theme = 1;
    gtk4.extraConfig.gtk-application-prefer-dark-theme = 1;
  };

  qt = {
    enable = true;
    platformTheme.name = "qtct";
    style.name = "kvantum";
  };
  systemd.user.services = {
    quickshell.Unit = {
      After = lib.mkForce [ "wayland-session-waitenv.service" ];
      PartOf = [ sessionTarget ];
      ConditionEnvironment = "WAYLAND_DISPLAY";
    };

    wave-blackout = {
      Unit.Description = "Trigger the Quickshell display blackout";
      Service = {
        Type = "oneshot";
        ExecStart = "${lib.getExe pkgs.quickshell} -c wave ipc call blackout trigger";
      };
    };

    wave-backlight-dim = {
      Unit = {
        Description = "Cancellable idle backlight dimmer";
        PartOf = [
          sessionTarget
          "hypridle.service"
        ];
      };
      Service = {
        Type = "simple";
        ExecStart = lib.getExe backlightDim;
        TimeoutStopSec = 3;
      };
    };

    wave-lid-handler = {
      Unit = {
        Description = "Hyprland-aware laptop lid policy";
        After = [
          "wayland-session-waitenv.service"
          "quickshell.service"
        ];
        PartOf = [ sessionTarget ];
        ConditionEnvironment = "WAYLAND_DISPLAY";
      };
      Service = {
        ExecStart = "${pkgs.systemd}/bin/systemd-inhibit --what=handle-lid-switch --mode=block --who=wave-lid-handler --why='Wave lid policy is healthy' ${lib.getExe lidHandler}";
        Restart = "always";
        RestartSec = 1;
      };
      Install.WantedBy = [ sessionTarget ];
    };

    hyprsunset = {
      Unit = {
        Description = "Hyprsunset color temperature daemon";
        After = [ "wayland-session-waitenv.service" ];
        PartOf = [ sessionTarget ];
        ConditionEnvironment = "WAYLAND_DISPLAY";
      };
      Service = {
        ExecStart = "${lib.getExe pkgs.hyprsunset} --identity";
        Restart = "on-failure";
        RestartSec = 1;
      };
      Install.WantedBy = [ sessionTarget ];
    };

    wave-night-light = {
      Unit = {
        Description = "Location-aware civil-twilight night light";
        Wants = [ "geoclue-agent.service" ];
        After = [
          "wayland-session-waitenv.service"
          "hyprsunset.service"
          "geoclue-agent.service"
        ];
        Requires = [ "hyprsunset.service" ];
        PartOf = [ sessionTarget ];
        ConditionEnvironment = "WAYLAND_DISPLAY";
      };
      Service = {
        ExecStart = lib.getExe nightLight;
        Restart = "always";
        RestartSec = 5;
      };
      Install.WantedBy = [ sessionTarget ];
    };

  };

  wayland.windowManager.hyprland = {
    enable = true;
    configType = "lua";
    package = null;
    portalPackage = null;
    systemd.enable = false;
    extraConfig = builtins.readFile ./desktop/hyprland.lua;
  };
}
