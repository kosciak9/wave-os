{ inputs, pkgs, ... }:

{
  home.packages = [
    pkgs.opencode
    pkgs.camofox-browser-cli
  ];

  programs.zsh.generatedCompletions.opencode = "${pkgs.opencode}/bin/opencode --completions zsh";

  xdg.configFile = {
    "opencode/commands" = {
      source = ./config/commands;
      force = true;
      recursive = true;
    };
    "opencode/opencode.jsonc" = {
      source = ./config/opencode.jsonc;
      force = true;
    };
    "opencode/plugins/herdr-agent-state.js".source =
      inputs.herdr + "/src/integration/assets/opencode/herdr-agent-state.js";
    "opencode/herdr-tui-session.js".source =
      inputs.herdr + "/src/integration/assets/opencode/herdr-tui-session.js";
    "opencode/cli.json" = {
      source = ./config/cli.json;
      force = true;
    };
  };
}
