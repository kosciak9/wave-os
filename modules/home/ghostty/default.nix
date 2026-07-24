{
  config,
  ghosttyCursorShaders,
  pkgs,
  ...
}:

{
  programs.ghostty = {
    enable = true;
    package = if pkgs.stdenv.isLinux then pkgs.ghostty else null;
    settings = {
      font-family = [
        "OverpassM Nerd Font"
        "Symbols Nerd Font Mono"
        "Noto Sans Symbols"
        "Noto Sans Symbols 2"
        "Noto Sans"
        "Noto Color Emoji"
      ];
      font-style-italic = false;
      font-style-bold-italic = false;
      font-size = 11;
      window-padding-x = 16;
      window-padding-y = 16;
      window-inherit-font-size = false;
      theme = "kanagawa";
      cursor-style = "underline";
      custom-shader = [ "${config.xdg.configHome}/ghostty/shaders/cursor_warp.glsl" ];
      shell-integration-features = "no-cursor,ssh-env,ssh-terminfo,sudo,title";
    };
    themes.kanagawa = {
      palette = [
        "0=#16161d"
        "1=#c34043"
        "2=#76946a"
        "3=#c0a36e"
        "4=#7e9cd8"
        "5=#957fb8"
        "6=#6a9589"
        "7=#c8c093"
        "8=#727169"
        "9=#e82424"
        "10=#98bb6c"
        "11=#e6c384"
        "12=#7fb4ca"
        "13=#938aa9"
        "14=#7aa89f"
        "15=#dcd7ba"
      ];
      background = "1f1f28";
      foreground = "dcd7ba";
      cursor-color = "c8c093";
      selection-background = "2d4f67";
      selection-foreground = "c8c093";
    };
  };

  xdg.configFile = {
    "ghostty/shaders".source = ghosttyCursorShaders;
  };
}
