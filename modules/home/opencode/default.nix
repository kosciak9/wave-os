{ pkgs, ... }:

{
  home.packages = [ pkgs.opencode ];

  xdg.configFile = {
    "opencode/agent" = {
      source = ./config/agent;
      force = true;
      recursive = true;
    };
    "opencode/command" = {
      source = ./config/command;
      force = true;
      recursive = true;
    };
    "opencode/opencode-quota" = {
      source = ./config/opencode-quota;
      force = true;
      recursive = true;
    };
    "opencode/opencode.jsonc" = {
      source = ./config/opencode.jsonc;
      force = true;
    };
    "opencode/plugin" = {
      source = ./config/plugin;
      force = true;
      recursive = true;
    };
    "opencode/tui.jsonc" = {
      source = ./config/tui.jsonc;
      force = true;
    };
  };
}
