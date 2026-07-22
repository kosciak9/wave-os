{
  config,
  lib,
  pkgs,
  inputs,
  kanagawa-kvantum,
  ...
}:

let
  wallpaper = "/home/kosciak/.config/secrets/wallpapers/kanagawa-black-centered.png";
in
{
  imports = [
    ../../modules/home/git.nix
    ../../modules/home/neovim
    ../../modules/home/opencode
    ../../modules/home/starship
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
      QT_QPA_PLATFORM = "wayland;xcb";
      QT_STYLE_OVERRIDE = "kvantum";
    };
    packages = with pkgs; [
      brightnessctl
      chromium
      fd
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
      nvimrc = "$EDITOR ~/projects/personal/wave-os/modules/home/neovim/config/init.lua";
      rm = "echo 'This is not the command you are looking for.'; false";
      sudo = "sudo ";
      vim = "nvim";
      vimrc = "$EDITOR ~/projects/personal/wave-os/modules/home/neovim/config/init.lua";
      sc-suspend = "systemctl suspend";
      zshrc = "$EDITOR ~/projects/personal/wave-os/hosts/jayce/home.nix";
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
    quickshell = {
      enable = true;
      activeConfig = "wave";
      configs.wave = ./desktop/quickshell;
      systemd = {
        enable = true;
        target = "graphical-session.target";
      };
    };
    password-store.enable = true;
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
        bind h select-pane -L
        bind l select-pane -R
        bind k select-pane -U
        bind j select-pane -D
        set-option -g allow-rename off
        set-option -g focus-events on
        set-option -sa terminal-features ',xterm-ghostty:RGB'
        set -g status-style bg='#1f1f28'
        set -g @prefix_highlight_prefix_prompt ' λ '
        set -g @prefix_highlight_fg '#FF9E3B'
        set -g @prefix_highlight_bg 'black'
        set -g status-left '#[fg=#54546D]  #S  '
        set -g status-right '#{prefix_highlight}'
        set -g window-status-format '#[fg=#49443C] #I '
        set -g window-status-current-format '#[fg=black,bg=#727169] #I '
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
    configType = "lua";
    package = null;
    portalPackage = null;
    systemd.enable = false;
    extraConfig = builtins.readFile ./desktop/hyprland.lua;
  };
}
