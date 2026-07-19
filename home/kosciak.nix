{
  config,
  lib,
  pkgs,
  inputs,
  kanagawa-kvantum,
  ...
}:

let
  wallpaper =
    pkgs.runCommand "kanagawa-wallpaper.png" { nativeBuildInputs = [ pkgs.imagemagick ]; }
      ''
        magick -size 2560x1600 'xc:#1f1f28' "png:$out"
      '';
in
{
  home = {
    username = "kosciak";
    homeDirectory = "/home/kosciak";
    stateVersion = "26.05";
    sessionPath = [ "$HOME/.local/bin" ];
    sessionVariables = {
      GTK_USE_PORTAL = "1";
      QT_QPA_PLATFORM = "wayland;xcb";
      QT_STYLE_OVERRIDE = "kvantum";
    };
    packages = with pkgs; [
      brightnessctl
      fd
      git-credential-manager
      hyprsunset
      hyprshot
      kanagawa-kvantum
      kdePackages.qtstyleplugin-kvantum
      nerd-fonts.overpass
      nerd-fonts.symbols-only
      nodejs
      opencode
      playerctl
      ripgrep
      trash-cli
      vicinae
      wl-clipboard
      inputs.zen-browser.packages.${pkgs.stdenv.hostPlatform.system}.default
    ];
  };

  programs.home-manager.enable = true;
  xdg.enable = true;

  xdg.userDirs = {
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

  programs.git = {
    enable = true;
    settings = {
      user = {
        name = "Franciszek Madej";
        email = "f.madej@protonmail.com";
      };
      core = {
        editor = "nvim";
      };
      credential = {
        helper = "manager";
        credentialStore = "secretservice";
      };
      init.defaultBranch = "main";
      pull.rebase = true;
      rerere.enabled = true;
    };
  };

  programs.delta = {
    enable = true;
    enableGitIntegration = true;
  };

  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
    history = {
      append = true;
      extended = true;
      ignoreAllDups = true;
      ignoreDups = true;
      ignoreSpace = true;
      save = 10000000;
      size = 10000000;
      share = true;
    };
    oh-my-zsh = {
      enable = true;
      plugins = [
        "git"
        "pass"
        "systemd"
        "vi-mode"
      ];
    };
    shellAliases = {
      n = "nvim";
      vim = "nvim";
      l = "eza --git --header --group --all --long";
      rm = "echo 'Use trash instead of rm.'; false";
      sc-suspend = "systemctl suspend";
    };
    initContent = ''
      export FZF_DEFAULT_COMMAND="fd --hidden --follow --exclude .git --exclude node_modules"
      export FZF_DEFAULT_OPTS="--layout=reverse --color=fg:#dcd7ba,bg:#1f1f28,hl:#7e9cd8 --color=fg+:#dcd7ba,bg+:#2a2a37,hl+:#7fb4ca"

      oc() {
        export OPENCODE_SERVER_PASSWORD="''${OPENCODE_SERVER_PASSWORD:-$(pass show opencode.localhost/opencode)}"
        command opencode attach localhost:51199 --dir "$PWD" "$@"
      }
    '';
  };

  programs = {
    eza.enable = true;
    fzf = {
      enable = true;
      enableZshIntegration = true;
    };
    neovim = {
      enable = true;
      defaultEditor = true;
      viAlias = true;
      vimAlias = true;
      extraPackages = with pkgs; [
        gcc
        gnumake
      ];
    };
    password-store.enable = true;
    starship = {
      enable = true;
      enableZshIntegration = true;
      settings = {
        add_newline = false;
        format = "$character$directory";
        right_format = "$username$hostname$git_branch$git_status$nix_shell$cmd_duration$container";
        character = {
          success_symbol = "[>](bold green)";
          error_symbol = "[x](bold red)";
          vimcmd_symbol = "[<](bold blue)";
        };
        git_branch.symbol = "git ";
        nix_shell.symbol = "nix ";
        container.format = "[@ [$name]]($style) ";
      };
    };
    tmux = {
      enable = true;
      baseIndex = 1;
      escapeTime = 10;
      historyLimit = 50000;
      keyMode = "vi";
      prefix = "C-a";
      terminal = "screen-256color";
      plugins = with pkgs.tmuxPlugins; [
        sensible
        prefix-highlight
      ];
      extraConfig = ''
        set-option -g allow-rename off
        set-option -g focus-events on
        set-option -sa terminal-features ',xterm-ghostty:RGB'
        set -g status-style bg='#1f1f28'
      '';
    };
    ghostty = {
      enable = true;
      settings = {
        font-family = "OverpassM Nerd Font";
        font-size = 11;
        window-padding-x = 16;
        window-padding-y = 16;
        theme = "kanagawa";
        cursor-style = "underline";
        shell-integration-features = "cursor,ssh-env,ssh-terminfo,sudo,title";
      };
    };
    hyprlock = {
      enable = true;
      settings = {
        general.hide_cursor = true;
        auth.fingerprint.enabled = true;
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
            outer_color = "rgb(126, 156, 216)";
            inner_color = "rgb(31, 31, 40)";
            font_color = "rgb(220, 215, 186)";
            font_family = "OverpassM Nerd Font Mono";
            fade_on_empty = true;
            placeholder_text = "";
            position = "0, 30";
            halign = "center";
            valign = "bottom";
          }
        ];
        label = [
          {
            monitor = "";
            text = ''cmd[update:1000] date +"%H:%M"'';
            color = "rgb(220, 215, 186)";
            font_size = 100;
            font_family = "OverpassM Nerd Font Mono Bold";
            position = "0, 120";
            halign = "center";
            valign = "center";
          }
        ];
      };
    };
    zoxide = {
      enable = true;
      enableZshIntegration = true;
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

  xdg.configFile = {
    "ghostty/themes/kanagawa".text = ''
      palette = 0=#16161d
      palette = 1=#c34043
      palette = 2=#76946a
      palette = 3=#c0a36e
      palette = 4=#7e9cd8
      palette = 5=#957fb8
      palette = 6=#6a9589
      palette = 7=#c8c093
      palette = 8=#727169
      palette = 9=#e82424
      palette = 10=#98bb6c
      palette = 11=#e6c384
      palette = 12=#7fb4ca
      palette = 13=#938aa9
      palette = 14=#7aa89f
      palette = 15=#dcd7ba
      background = 1f1f28
      foreground = dcd7ba
      cursor-color = c8c093
      selection-background = 2d4f67
      selection-foreground = c8c093
    '';
    "Kvantum/Kanagawa".source = "${kanagawa-kvantum}/share/Kvantum/Kanagawa";
    "Kvantum/kvantum.kvconfig".text = ''
      [General]
      theme=Kanagawa
    '';
  };

  services.hypridle = {
    enable = true;
    settings = {
      general = {
        lock_cmd = "pidof hyprlock || hyprlock";
        before_sleep_cmd = "loginctl lock-session";
        after_sleep_cmd = "hyprctl dispatch dpms on";
      };
      listener = [
        {
          timeout = 300;
          on-timeout = "loginctl lock-session";
        }
        {
          timeout = 600;
          on-timeout = "hyprctl dispatch dpms off";
          on-resume = "hyprctl dispatch dpms on";
        }
        {
          timeout = 1800;
          on-timeout = "systemctl suspend";
        }
      ];
    };
  };

  services.hyprpaper = {
    enable = true;
    settings = {
      ipc = "on";
      splash = false;
      preload = [ "${wallpaper}" ];
      wallpaper = [ ",${wallpaper}" ];
    };
  };

  systemd.user.services.vicinae = {
    Unit = {
      Description = "Vicinae launcher daemon";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      ExecStart = "${lib.getExe pkgs.vicinae} server --replace";
      Restart = "on-failure";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  wayland.windowManager.hyprland = {
    enable = true;
    configType = "hyprlang";
    package = null;
    portalPackage = null;
    systemd.enable = false;
    settings = {
      monitor = [
        "eDP-1,2560x1600@165,0x0,1.5,vrr,1"
        "desc:GIGA-BYTE TECHNOLOGY CO.\\, LTD. M28U 24030B004813,3840x2160@143.999,0x-900,1.8"
        "desc:Dell Inc. DELL P2720DC H88QK53,2560x1440@59.951,0x0,1.25"
        "desc:Dell Inc. DELL P2720D D94ZS03,2560x1440@59.951,2048x0,1.25"
        ",preferred,auto,auto"
      ];

      input = {
        kb_layout = "pl";
        follow_mouse = 1;
        touchpad = {
          tap-to-click = true;
          disable_while_typing = true;
          natural_scroll = true;
          scroll_factor = 0.1;
        };
      };

      general = {
        layout = "scrolling";
        gaps_in = 8;
        gaps_out = 24;
        border_size = 2;
        "col.active_border" = "rgb(938056)";
        "col.inactive_border" = "rgb(717c7c)";
      };

      scrolling.fullscreen_on_one_column = true;
      decoration = {
        rounding = 4;
        shadow.enabled = true;
      };
      misc = {
        disable_hyprland_logo = true;
        force_default_wallpaper = 0;
      };

      bind = [
        "SUPER, RETURN, exec, ghostty"
        "SUPER, SPACE, exec, vicinae toggle"
        "SUPER ALT, L, exec, loginctl lock-session"
        "SUPER, W, killactive"
        "SUPER, H, movefocus, l"
        "SUPER, J, movefocus, d"
        "SUPER, K, movefocus, u"
        "SUPER, L, movefocus, r"
        "SUPER CTRL, H, movewindow, l"
        "SUPER CTRL, J, movewindow, d"
        "SUPER CTRL, K, movewindow, u"
        "SUPER CTRL, L, movewindow, r"
        "SUPER, F, fullscreen, 1"
        "SUPER SHIFT, F, fullscreen, 0"
        "SUPER, V, togglefloating"
        "SUPER SHIFT, E, exit"
        ", Print, exec, hyprshot -m region"
      ]
      ++ (builtins.concatLists (
        builtins.genList (
          i:
          let
            workspace = i + 1;
            key = if workspace == 10 then "0" else toString workspace;
          in
          [
            "SUPER, ${key}, workspace, ${toString workspace}"
            "SUPER CTRL, ${key}, movetoworkspace, ${toString workspace}"
          ]
        ) 10
      ));

      bindel = [
        ", XF86AudioRaiseVolume, exec, wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+"
        ", XF86AudioLowerVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"
        ", XF86MonBrightnessUp, exec, brightnessctl -e4 -n2 set 5%+"
        ", XF86MonBrightnessDown, exec, brightnessctl -e4 -n2 set 5%-"
      ];
      bindl = [
        ", XF86AudioMute, exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"
        ", XF86AudioMicMute, exec, wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"
        ", XF86AudioPlay, exec, playerctl play-pause"
        ", XF86AudioNext, exec, playerctl next"
        ", XF86AudioPrev, exec, playerctl previous"
      ];
      bindm = [
        "SUPER, mouse:272, movewindow"
        "SUPER, mouse:273, resizewindow"
      ];
    };
  };
}
