{ pkgs, ... }:

{
  home.packages = [
    pkgs.opencode
    pkgs.opencode2
    pkgs.camofox-browser-cli
  ];

  # Keep the v2 installation completely separate from the v1 XDG config.
  home.file.".config/opencode-v2/opencode" = {
    source = ./config-v2;
    force = true;
    recursive = true;
  };

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
    "opencode/skills" = {
      source = ./config/skills;
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
