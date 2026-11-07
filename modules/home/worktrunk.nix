{ config, ... }:
{
  programs.worktrunk = {
    enable = true;
    enableZshIntegration = true;
    settings = {
      # Same layout as T3's worktreesDirectory: <dir>/<repo>/<branch>.
      worktree-path = "${config.home.homeDirectory}/Developer/worktrees/{{ repo }}/{{ branch | sanitize }}";
      skip-commit-generation-prompt = true;
      # Keep every commit of a branch: `wt merge` rebases and fast-forwards
      # without squashing.
      merge.squash = false;
    };
  };
  # Replaces the hand-edited file whose settings now live above.
  xdg.configFile."worktrunk/config.toml".force = true;
}
