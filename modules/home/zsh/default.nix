{
  config,
  lib,
  pkgs,
  ...
}:

{
  options.programs.zsh.generatedCompletions = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = { };
    description = ''
      Completion scripts for commands whose packages ship none, keyed by command name. Each value
      is a shell command that prints the zsh completion script; it runs at build time.
    '';
  };

  config = {
    home.language = {
      base = "en_US.UTF-8";
      ctype = "en_US.UTF-8";
    };

    home.packages = [
      pkgs.mosh
      pkgs.zsh-completions
      (pkgs.runCommand "zsh-generated-completions" { } ''
        mkdir -p "$out/share/zsh/site-functions"
        export HOME="$TMPDIR"
        ${lib.concatLines (
          lib.mapAttrsToList (
            command: generate: ''${generate} > "$out/share/zsh/site-functions/_${command}"''
          ) config.programs.zsh.generatedCompletions
        )}
      '')
    ];

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
          nvimrc = "$EDITOR ~/Developer/personal/wave-os/modules/home/neovim/config/init.lua";
          oc = "opencode";
          sudo = "sudo ";
          vim = "nvim";
          vimrc = "$EDITOR ~/Developer/personal/wave-os/modules/home/neovim/config/init.lua";
          zshrc = "$EDITOR ~/Developer/personal/wave-os/modules/home/zsh/default.nix";
        };
        initContent = lib.mkMerge [
          (lib.mkOrder 850 ''
            if [[ -n $TTY && $options[zle] = on ]]; then
              ZVM_INIT_MODE=sourcing
              source "${pkgs.zsh-vi-mode}/share/zsh-vi-mode/zsh-vi-mode.plugin.zsh"
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

            zstyle ':fzf-tab:complete:cd:*' disabled-on any

            ssh() {
              emulate -L zsh -o extended_glob
              # Plain terminal logins use Mosh; mosh-server sets its own TERM, so no terminfo is needed.
              if [[ -o interactive && -t 0 && -t 1 && $# -eq 1 && $1 != -* && $1 != ssh://* ]]; then
                command mosh -- "$1"
                return
              fi
              local term=$TERM
              local -a opts
              # Replaces Ghostty's ssh-env and ssh-terminfo integration: install xterm-ghostty on the
              # remote once (remembered by `ghostty +ssh-cache`), else fall back to xterm-256color.
              if [[ $TERM == xterm-ghostty ]]; then
                opts=(-o "SetEnv COLORTERM=truecolor" -o "SendEnv TERM_PROGRAM TERM_PROGRAM_VERSION")
                term=xterm-256color
                local ghostty=''${GHOSTTY_BIN_DIR:+$GHOSTTY_BIN_DIR/}ghostty key value user host cpath
                # Options and destination without the remote command, which must not run twice.
                local -i i=1
                local rest
                while (( i <= $# )); do
                  case ''${@[i]} in
                    --) (( i++ )); break ;;
                    -?*)
                      # After ssh's valueless flags, a lone option letter takes the next word.
                      rest=''${''${@[i]}##-[46AaCfGgKkMNnqsTtVvXxYy]#}
                      (( i += ''${#rest} == 1 ? 2 : 1 ))
                      ;;
                    *) break ;;
                  esac
                done
                local -a target=("''${@[1,i]}")
                while read -r key value; do
                  case $key in
                    user) user=$value ;;
                    hostname) host=$value ;;
                  esac
                  [[ -n $user && -n $host ]] && break
                done < <(command ssh -G "$@" 2>/dev/null)
                if [[ -n $host ]]; then
                  if "$ghostty" +ssh-cache --host="$user@$host" >/dev/null 2>&1; then
                    term=xterm-ghostty
                  else
                    cpath="$(mktemp -d "''${TMPDIR:-/tmp}/ghostty-ssh.XXXXXX")/socket"
                    if infocmp -0 -x xterm-ghostty 2>/dev/null | command ssh "''${opts[@]}" \
                      -o ControlMaster=yes -o ControlPath="$cpath" -o ControlPersist=60s "''${target[@]}" '
                        infocmp xterm-ghostty >/dev/null 2>&1 && exit 0
                        command -v tic >/dev/null 2>&1 && mkdir -p ~/.terminfo && tic -x - 2>/dev/null
                      ' 2>/dev/null; then
                      term=xterm-ghostty
                      opts+=(-o "ControlPath=$cpath")
                      "$ghostty" +ssh-cache --add="$user@$host" >/dev/null 2>&1
                    fi
                  fi
                fi
              fi
              TERM=$term command ssh "''${opts[@]}" "$@"
            }

            cpu_count() {
              if (( $+commands[nproc] )); then
                nproc
              else
                sysctl -n hw.ncpu
              fi
            }
            export MIX_OS_DEPS_COMPILE_PARTITION_COUNT=$(( $(cpu_count) / 2 ))

          '')
        ];
      };
    };
  };
}
