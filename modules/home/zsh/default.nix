{
  lib,
  pkgs,
  ...
}:

{
  home.packages = [ pkgs.zsh-completions ];

  programs = {
    eza = {
      enable = true;
      enableZshIntegration = false;
    };
    fzf = {
      enable = true;
      enableZshIntegration = false;
    };
    zsh = {
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
        gcawip = "git commit --amend --no-verify -m wip";
        gcwip = "git commit --no-verify -m wip";
        l = "eza --git -h -g -H -l";
        n = "nvim";
        nvimrc = "$EDITOR ~/projects/personal/wave-os/modules/home/neovim/config/init.lua";
        sudo = "sudo ";
        vim = "nvim";
        vimrc = "$EDITOR ~/projects/personal/wave-os/modules/home/neovim/config/init.lua";
        zshrc = "$EDITOR ~/projects/personal/wave-os/modules/home/zsh/default.nix";
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
            export OPENCODE_SERVER_USERNAME="''${OPENCODE_SERVER_USERNAME:-opencode}"
            export OPENCODE_SERVER_PASSWORD="''${OPENCODE_SERVER_PASSWORD:-$(pass show opencode.localhost/opencode)}"
            command opencode attach "$OPENCODE_ATTACH_TARGET" --dir "$PWD" "$@"
          }
        '')
      ];
    };
  };
}
