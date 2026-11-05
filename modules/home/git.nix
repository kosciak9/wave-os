{ pkgs, ... }:

let
  gitIni = pkgs.formats.gitIni { };
in
{
  xdg.configFile = {
    # Replaces the unmanaged config.yml that gh wrote on first login.
    "gh/config.yml".force = true;
    "git/config.d/personal".source = gitIni.generate "gitconfig-personal" {
      user = {
        name = "Franciszek Madej";
        email = "f.madej@protonmail.com";
      };
    };
    "git/config.d/alergeek".source = gitIni.generate "gitconfig-alergeek" {
      user = {
        name = "Franciszek Madej";
        email = "franek@alergeek.ventures";
      };
    };
  };

  home.packages = with pkgs; [
    difftastic
    git-absorb
  ];

  programs = {
    git = {
      enable = true;
      lfs.enable = true;
      includes = [
        { path = "config.d/personal"; }
        {
          condition = "gitdir:~/Developer/alergeek/";
          path = "config.d/alergeek";
        }
      ];
      settings = {
        core = {
          editor = "nvim";
          pager = "delta";
        };
        absorb = {
          maxStack = 100;
          oneFixupPerCommit = true;
          autoStageIfNothingStaged = true;
          fixupTargetAlwaysSHA = true;
          forceAuthor = true;
        };
        difftool = {
          prompt = false;
          difftastic.cmd = "difft \"$LOCAL\" \"$REMOTE\"";
        };
        pager.difftool = true;
        color.ui = true;
        alias = {
          lg = "lg1";
          lg1 = "lg1-specific --all";
          lg2 = "lg2-specific --all";
          lg3 = "lg3-specific --all";
          lg1-specific = "log --graph --abbrev-commit --decorate --format=format:'%C(bold blue)%h%C(reset) - %C(bold green)(%ar)%C(reset) %C(white)%s%C(reset) %C(dim white)- %an%C(reset)%C(auto)%d%C(reset)'";
          lg2-specific = "log --graph --abbrev-commit --decorate --format=format:'%C(bold blue)%h%C(reset) - %C(bold cyan)%aD%C(reset) %C(bold green)(%ar)%C(reset)%C(auto)%d%C(reset)%n''          %C(white)%s%C(reset) %C(dim white)- %an%C(reset)'";
          lg3-specific = "log --graph --decorate --format=format:'%C(bold blue)%h%C(reset) - %C(bold cyan)%aD%C(reset) %C(bold green)(%ar)%C(reset) %C(bold cyan)(committed: %cD)%C(reset) %C(auto)%d%C(reset)%n''          %C(white)%s%C(reset)%n''          %C(dim white)- %an <%ae> %C(reset) %C(dim white)(committer: %cn <%ce>)%C(reset)'";
          spellcheck = false;
          prune-branches = "!git remote prune origin && git branch -vv | grep ': gone]' | awk '{print $1}' | xargs -r git branch -d";
          dft = "difftool";
          difft = "!difft";
        };
        # Clear lower-priority helpers such as Darwin osxkeychain; GitHub HTTPS uses gh below.
        credential.helper = "";
        init.defaultBranch = "main";
        pull.rebase = true;
        rerere.enabled = true;
      };
    };

    # Its git credential helper lets HTTPS GitHub remotes push with the token from `gh auth login`.
    gh = {
      enable = true;
      settings.aliases.co = "pr checkout";
    };

    delta = {
      enable = true;
      enableGitIntegration = true;
    };
  };
}
