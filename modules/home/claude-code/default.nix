{
  config,
  pkgs,
  ...
}:
{
  home.file."${config.programs.claude-code.configDir}/skills".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/.agents/skills";

  programs.claude-code = {
    enable = true;
    package = pkgs.claude-code;
    settings = {
      env = {
        DISABLE_AUTOUPDATER = "1";
      };
      enabledPlugins."agents-md@builtin" = true;
      pluginConfigs."agents-md@builtin".options.instructionFiles = "claude-md-and-agents-md";
      syncClaudeAiSkills = false;
    };
  };
}
