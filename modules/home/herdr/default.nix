{
  inputs,
  lib,
  pkgs,
  ...
}:

let
  herdr = inputs.herdr.packages.${pkgs.stdenv.hostPlatform.system}.herdr;
  worktrunk = pkgs.worktrunk.overrideAttrs {
    # TODO: Re-enable checks when Worktrunk process-table tests support Darwin sandboxes.
    # Darwin sandboxes hide the process table, breaking upstream shell-probe tests.
    # Skip the slow test suite there; Linux keeps the nixpkgs checks enabled.
    doCheck = !pkgs.stdenv.hostPlatform.isDarwin;
  };
in
{
  home.packages = with pkgs; [
    herdr
    antigravity-cli
    bash
    claude-code
    codex
    fzf
    jq
    worktrunk
  ];

  xdg.configFile."herdr/config.toml".text = ''
    [[keys.command]]
    key = "prefix+shift+g"
    type = "plugin_action"
    command = "worktrunk.open"
    description = "Worktree: switch or create from default branch"

    [[keys.command]]
    key = "prefix+shift+c"
    type = "plugin_action"
    command = "worktrunk.open-current"
    description = "Worktree: switch or create from current branch"

    [[keys.command]]
    key = "prefix+shift+r"
    type = "plugin_action"
    command = "worktrunk.open-with-remotes"
    description = "Worktree: switch or create from remote branch"

    [[keys.command]]
    key = "prefix+shift+d"
    type = "plugin_action"
    command = "worktrunk.remove"
    description = "Worktree: remove"
  '';

  # Nix owns registration and enabled state; Herdr manages the mutable registry.
  home.activation.herdrWorktrunk = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    run ${lib.getExe herdr} plugin link ${lib.escapeShellArg (toString inputs.herdr-worktrunk)} --enabled
  '';
}
