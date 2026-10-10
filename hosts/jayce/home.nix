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
  zenBrowser = inputs.zen-browser.packages.${pkgs.stdenv.hostPlatform.system}.default;
  quickshellWithMultimedia = pkgs.quickshell.overrideAttrs (old: {
    buildInputs = (old.buildInputs or [ ]) ++ [ pkgs.kdePackages.qtmultimedia ];
  });
  notificationSoundPath = "${pkgs.sound-theme-freedesktop}/share/sounds/freedesktop/stereo/message-new-instant.oga";
  waytator = pkgs.callPackage ../../packages/waytator.nix { };
  dim = pkgs.writeShellApplication {
    name = "wave-dim";
    runtimeInputs = with pkgs; [
      brightnessctl
      coreutils
      hyprland
      jq
      qmk_hid
    ];
    text = builtins.readFile ./scripts/dim.sh;
  };
  waveDisplay = "${lib.getExe pkgs.wave} display";
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
    ./desktop/itd.nix
    ./desktop/voxtype.nix
    ./pimalaya.nix
    ../../modules/home/agents
    ../../modules/home/cli
    ../../modules/home/camofox/linux.nix
    ../../modules/home/devenv
    ../../modules/home/ghostty
    ../../modules/home/git.nix
    ../../modules/home/neovim
    ../../modules/home/opencode
    ../../modules/home/herdr
    ../../modules/home/herdr/gpui.nix
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
      QT_QPA_PLATFORM = "wayland";
      _JAVA_AWT_WM_NONREPARENTING = "1";
      QT_STYLE_OVERRIDE = "kvantum";
    };
    packages = with pkgs; [
      brightnessctl
      chromium
      fd
      gimp
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
      remmina
      ripgrep
      trash-cli
      tesseract
      waytator
      wl-clipboard
      zenBrowser
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
    herdr.federation = {
      coordinator = true;
      savedMachines = {
        "9bb12fa0ed8a8e7cf7c014b24abcb2fb" = "machine_77b726453c93d640ca177e4d8ac56139";
        "8ac324f745614d28882c5758333e4b42" = "machine_9026bebb6184fc9965a24b867836dce9";
      };
    };
    home-manager.enable = true;
    zen-browser = {
      enable = true;
      package = zenBrowser;
      profileName = "wave";
      settings = (import ../../modules/home/zen-browser/config/settings.nix) // {
        "browser.startup.homepage" = "https://wave.exposed";
        "browser.startup.page" = 1;
      };
    };
    quickshell = {
      enable = true;
      package = quickshellWithMultimedia;
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
          before_sleep_cmd = "systemctl --user stop wave-dim.service; loginctl lock-session";
        };
        listener = [
          {
            timeout = 240;
            on-timeout = "systemctl --user start wave-dim.service";
            on-resume = "systemctl --user stop wave-dim.service";
          }
          {
            timeout = 300;
            on-timeout = "loginctl lock-session";
          }
          {
            timeout = 600;
            on-timeout = "hyprctl dispatch 'hl.dsp.dpms({ action = \"disable\" })'";
            on-resume = "${waveDisplay} notify display-on";
          }
          {
            timeout = 900;
            on-timeout = "${waveDisplay} notify idle-start";
            on-resume = "${waveDisplay} notify idle-end";
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
    mpris-proxy.enable = true;
  };

  xdg = {
    enable = true;
    userDirs = {
      enable = true;
      createDirectories = true;
      desktop = "$HOME";
      download = "$HOME/Downloads";
      templates = "$HOME";
      publicShare = "$HOME/Public";
      documents = "$HOME/Documents";
      music = "$HOME/Media";
      pictures = "$HOME/Media";
      videos = "$HOME/Media";
    };
    configFile = {
      "Kvantum/Kanagawa".source = "${kanagawa-kvantum}/share/Kvantum/Kanagawa";
      "Kvantum/kvantum.kvconfig".text = ''
        [General]
        theme=Kanagawa
      '';
      "gtk-4.0/assets".source = "${pkgs.kanagawa-gtk-theme}/share/themes/Kanagawa-Dark/gtk-4.0/assets";
      "gtk-4.0/gtk.css".source = "${pkgs.kanagawa-gtk-theme}/share/themes/Kanagawa-Dark/gtk-4.0/gtk.css";
      "gtk-4.0/gtk-dark.css".source =
        "${pkgs.kanagawa-gtk-theme}/share/themes/Kanagawa-Dark/gtk-4.0/gtk-dark.css";
      # Remmina recreates its tray applet autostart entry whenever the file is missing.
      "autostart/remmina-applet.desktop" = {
        force = true;
        text = ''
          [Desktop Entry]
          Type=Application
          Name=Remmina Applet
          Exec=remmina -i
          Hidden=true
        '';
      };
    };
  };

  gtk = {
    enable = true;
    theme = {
      name = "Kanagawa-Dark";
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
    wave-caffeinate = {
      Unit = {
        Description = "Keep tasks running at performance without preventing lock or DPMS";
        After = [ "wayland-session-waitenv.service" ];
        PartOf = [ sessionTarget ];
        ConditionEnvironment = "WAYLAND_DISPLAY";
      };
      Service = {
        Type = "notify";
        # A weak sleep lock allows root's critical-battery hibernation. The
        # session sleep policy explicitly respects it even for its owning UID.
        ExecStart = "${lib.getExe pkgs.wave} caffeinate hold";
        TimeoutStartSec = 10;
        TimeoutStopSec = 5;
      };
    };
    quickshell = {
      Unit = {
        After = lib.mkForce [ "wayland-session-waitenv.service" ];
        PartOf = [ sessionTarget ];
        ConditionEnvironment = "WAYLAND_DISPLAY";
        "X-Restart-Triggers" = [ "${./desktop/quickshell}" ];
      };
      Service = {
        Environment = [ "WAVE_NOTIFICATION_SOUND=${notificationSoundPath}" ];
        UMask = "0077";
      };
    };

    wave-blackout = {
      Unit.Description = "Trigger the Quickshell display blackout";
      Service = {
        Type = "oneshot";
        ExecStart = "${lib.getExe pkgs.quickshell} -c wave ipc call blackout trigger";
      };
    };

    wave-dim = {
      Unit = {
        Description = "Cancellable idle dimmer for the screen and keyboard backlights";
        PartOf = [
          sessionTarget
          "hypridle.service"
        ];
      };
      Service = {
        Type = "simple";
        ExecStart = lib.getExe dim;
        TimeoutStopSec = 3;
      };
    };

    wave-display = {
      Unit = {
        Description = "Wave session display policy for the lid, outputs, workspaces and sleep";
        After = [
          "wayland-session-waitenv.service"
          "quickshell.service"
        ];
        PartOf = [ sessionTarget ];
        ConditionEnvironment = "WAYLAND_DISPLAY";
      };
      Service = {
        ExecStart = "${waveDisplay} daemon";
        # Blackout goes through the Quickshell IPC client; qmk_hid drives the
        # keyboard backlight.
        Environment = [
          "PATH=${
            lib.makeBinPath [
              pkgs.qmk_hid
              pkgs.quickshell
            ]
          }"
        ];
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
    extraConfig = ''
      hl.plugin.load("${pkgs.hyprland-scroll-overview}/lib/scrolloverview.so")
      ${builtins.readFile ./desktop/hyprland.lua}
    '';
  };
}
