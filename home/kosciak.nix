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
      QT_QPA_PLATFORM = "wayland;xcb";
      QT_STYLE_OVERRIDE = "kvantum";
    };
    packages = with pkgs; [
      brightnessctl
      chromium
      fd
      git-credential-manager
      hyprsunset
      hyprshot
      (iosevka-bin.override { variant = "SGr-IosevkaTerm"; })
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
      opencode
      playerctl
      pulseaudio
      ripgrep
      trash-cli
      vicinae
      wl-clipboard
      worktrunk
      zsh-completions
      inputs.zen-browser.packages.${pkgs.stdenv.hostPlatform.system}.default
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
    fastSyntaxHighlighting.enable = true;
    history = {
      append = true;
      expireDuplicatesFirst = true;
      extended = true;
      findNoDups = true;
      ignoreAllDups = true;
      ignoreDups = true;
      ignorePatterns = [
        "ls*"
        "cd*"
        "pwd*"
        "exit*"
      ];
      ignoreSpace = true;
      saveNoDups = true;
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
      ];
    };
    setOptions = [
      "BANG_HIST"
      "HIST_BEEP"
      "HIST_REDUCE_BLANKS"
      "HIST_VERIFY"
      "INC_APPEND_HISTORY"
    ];
    shellAliases = {
      caffeinate = "echo 'preventing idle and lid sleep' && systemd-inhibit --what=idle:sleep:handle-lid-switch --who=caffeinate --why=Caffeinate sleep infinity";
      cp = "cp -rv --reflink=auto";
      gcawip = "git commit --amend --no-verify -m wip";
      gcwip = "git commit --no-verify -m wip";
      l = "eza --git -h -g -H -l";
      n = "nvim";
      nvimrc = "$EDITOR ~/projects/personal/wave-os/home/nvim/init.lua";
      rm = "echo 'This is not the command you are looking for.'; false";
      sudo = "sudo ";
      vim = "nvim";
      vimrc = "$EDITOR ~/projects/personal/wave-os/home/nvim/init.lua";
      sc-suspend = "systemctl suspend";
      zshrc = "$EDITOR ~/projects/personal/wave-os/home/kosciak.nix";
    };
    initContent = lib.mkMerge [
      (lib.mkOrder 850 ''
        if [[ -n $TTY && $options[zle] = on ]]; then
          source "$ZSH/plugins/vi-mode/vi-mode.plugin.zsh"
        fi
      '')
      (lib.mkOrder 900 ''
        if [[ -n $TTY && $options[zle] = on ]]; then
          source "${pkgs.zsh-fzf-tab}/share/fzf-tab/fzf-tab.plugin.zsh"
        fi
      '')
      (lib.mkOrder 910 ''
        if [[ -n $TTY && $options[zle] = on ]]; then
          source <("${lib.getExe pkgs.fzf}" --zsh)
        fi
      '')
      (lib.mkOrder 1000 ''
        if [[ -n $TTY && $options[zle] = on && $TERM != dumb ]]; then
          eval "$("${lib.getExe pkgs.starship}" init zsh)"
        fi

        export FZF_DEFAULT_COMMAND="fd --hidden --follow --exclude .git --exclude node_modules"
        export FZF_DEFAULT_OPTS='
          --layout=reverse
          --color=fg:#dcd7ba,bg:#1f1f28,hl:#7e9cd8
          --color=fg+:#dcd7ba,bg+:#2a2a37,hl+:#7fb4ca
          --color=info:#a3aab0,prompt:#d27e99,pointer:#957fb8
          --color=marker:#98bb6c,spinner:#957fb8,header:#7e9cd8'
        export OPENCODE_ATTACH_TARGET="''${OPENCODE_ATTACH_TARGET:-localhost:51199}"

        zstyle ':fzf-tab:complete:cd:*' disabled-on any

        if (( $+commands[wt] )); then
          eval "$(command wt config shell init zsh)"
        fi

        cpu_count() {
          if (( $+commands[nproc] )); then
            nproc
          else
            sysctl -n hw.ncpu
          fi
        }
        export MIX_OS_DEPS_COMPILE_PARTITION_COUNT=$(( $(cpu_count) / 2 ))

        oc() {
          export OPENCODE_SERVER_PASSWORD="''${OPENCODE_SERVER_PASSWORD:-$(pass show opencode.localhost/opencode)}"
          command opencode attach "$OPENCODE_ATTACH_TARGET" --dir "$PWD" "$@"
        }
      '')
    ];
  };

  programs = {
    eza = {
      enable = true;
      enableZshIntegration = false;
    };
    fzf = {
      enable = true;
      enableZshIntegration = false;
    };
    neovim = {
      enable = true;
      defaultEditor = true;
      viAlias = true;
      vimAlias = true;
      initLua = builtins.readFile ./nvim/init.lua;
      plugins = with pkgs.vimPlugins; [
        kanagawa-nvim
        hardtime-nvim
        nui-nvim
        gitsigns-nvim
        diffview-plus-nvim
        neogit
        nvim-ts-context-commentstring
        vim-matchup
        nvim-surround
        mini-icons
        mini-starter
        plenary-nvim
        telescope-nvim
        telescope-fzf-native-nvim
        nvim-lspconfig
        conform-nvim
        tiny-inline-diagnostic-nvim
        copilot-lsp
        copilot-lua
        (nvim-treesitter.withPlugins (
          parsers: with parsers; [
            markdown
            markdown_inline
            tsx
            javascript
            typescript
            json
            graphql
            python
            yaml
            html
            scss
            lua
            elixir
            heex
          ]
        ))
        oil-nvim
      ];
      extraPackages = with pkgs; [
        git
        ripgrep
        fd
        nodejs
        curl
        wl-clipboard

        lua-language-server
        harper
        vscode-langservers-extracted
        yaml-language-server
        beamPackages.expert
        typescript-go
        deno
        biome
        oxlint
        tailwindcss-language-server

        stylua
        ruff
        isort
        black
        oxfmt
        prettierd
        prettier
        markdownlint-cli
      ];
    };
    quickshell = {
      enable = true;
      activeConfig = "wave";
      configs.wave = ./quickshell;
      systemd = {
        enable = true;
        target = "graphical-session.target";
      };
    };
    password-store.enable = true;
    starship = {
      enable = true;
      enableZshIntegration = false;
      settings = builtins.fromTOML (builtins.readFile ./starship.toml);
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
        font-family = [
          "OverpassM Nerd Font"
          "Symbols Nerd Font Mono"
          "Noto Sans Symbols"
          "Noto Sans Symbols 2"
          "Noto Sans"
          "Noto Color Emoji"
        ];
        font-style-italic = false;
        font-style-bold-italic = false;
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
    "nvim/lsp".source = ./nvim/lsp;
    "nvim/lua".source = ./nvim/lua;
    "nvim/queries".source = ./nvim/queries;
    "opencode/agent".source = ./opencode/agent;
    "opencode/command".source = ./opencode/command;
    "opencode/opencode-quota".source = ./opencode/opencode-quota;
    "opencode/opencode.jsonc" = {
      source = ./opencode/opencode.jsonc;
      force = true;
    };
    "opencode/plugin".source = ./opencode/plugin;
    "opencode/tui.jsonc".source = ./opencode/tui.jsonc;
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
      wallpaper = [
        {
          monitor = "*";
          path = "${wallpaper}";
        }
      ];
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
        "eDP-1,2560x1600@165,0x0,1.6,vrr,1"
        "desc:GIGA-BYTE TECHNOLOGY CO.\\, LTD. M28U 24030B004813,3840x2160@143.999,0x-900,1.875"
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

      gesture = [
        "3, horizontal, scrollMove"
        "3, vertical, workspace"
      ];

      general = {
        layout = "scrolling";
        gaps_in = 8;
        gaps_out = 24;
        border_size = 2;
        "col.active_border" = "rgb(938056)";
        "col.inactive_border" = "rgb(717c7c)";
      };

      animations = {
        enabled = true;
        # Niri defaults: 150 ms open/close and critically damped movement.
        bezier = [
          "niriOpen, 0.155022, 1.056612, 0.360227, 0.981250"
          "niriClose, 0.333333, 0.666667, 0.666667, 1.000000"
          "niriSpring, 0.326467, 0.688594, 0.114413, 1.000000"
        ];
        animation = [
          "global, 1, 1.5, niriClose"
          "windows, 1, 3.2564, niriSpring"
          "windowsIn, 1, 1.5, niriOpen, popin 50%"
          "windowsOut, 1, 1.5, niriClose, popin 80%"
          "fadeIn, 1, 1.5, niriOpen"
          "fadeOut, 1, 1.5, niriClose"
          "layersIn, 1, 1.5, niriOpen, fade"
          "layersOut, 1, 1.5, niriClose, fade"
          "fadeLayersIn, 1, 1.5, niriOpen"
          "fadeLayersOut, 1, 1.5, niriClose"
          "workspaces, 1, 2.9126, niriSpring, slidevert"
        ];
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
