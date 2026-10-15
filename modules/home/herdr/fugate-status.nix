{ lib, pkgs }:

rec {
  statusHookPackage = pkgs.callPackage ../../../packages/fugate-status-hook.nix { };
  # Agent harnesses call the hook by store path, so it needs no PATH entry.
  statusHook = lib.getExe statusHookPackage;

  # OpenCode V2 loads a configured local plugin directory's tui.js in the TUI
  # process, which carries the pane's Herdr environment.
  opencodePlugin = pkgs.writeTextFile {
    name = "fugate-status-opencode";
    destination = "/tui.js";
    text = builtins.replaceStrings [ "@statusHook@" ] [ statusHook ] (
      builtins.readFile ./fugate-status-opencode.js
    );
  };
}
