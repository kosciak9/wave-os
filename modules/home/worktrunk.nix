{ pkgs, ... }:
let
  worktrunk = pkgs.worktrunk.overrideAttrs {
    # TODO: Re-enable checks when Worktrunk process-table tests support Darwin sandboxes.
    # Darwin sandboxes hide the process table, breaking upstream shell-probe tests.
    # Skip the slow test suite there; Linux keeps the nixpkgs checks enabled.
    doCheck = !pkgs.stdenv.hostPlatform.isDarwin;
  };
in
{
  programs.worktrunk = {
    enable = true;
    enableZshIntegration = true;
    package = worktrunk;
    settings = {
      worktree-path = "{{ repo_path }}/../.worktrees/{{ repo }}/{{ branch | sanitize }}";
      skip-commit-generation-prompt = true;
      # Keep every commit of a branch: `wt merge` rebases and fast-forwards
      # without squashing.
      merge.squash = false;
    };
  };
  # Replaces the hand-edited file whose settings now live above.
  xdg.configFile."worktrunk/config.toml".force = true;
}
