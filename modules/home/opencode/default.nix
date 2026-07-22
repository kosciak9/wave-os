{
  xdg.configFile = {
    "opencode/agent".source = ./config/agent;
    "opencode/command".source = ./config/command;
    "opencode/opencode-quota".source = ./config/opencode-quota;
    "opencode/opencode.jsonc" = {
      source = ./config/opencode.jsonc;
      force = true;
    };
    "opencode/plugin".source = ./config/plugin;
    "opencode/tui.jsonc".source = ./config/tui.jsonc;
  };
}
