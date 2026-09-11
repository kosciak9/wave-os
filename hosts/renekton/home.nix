{ ... }:
{
  imports = [
    ../../modules/home/openclaw
    ../../modules/home/camofox
    ../../modules/home/cli
    ../../modules/home/devenv
    ../../modules/home/development-caddy/darwin.nix
    ../../modules/home/ghostty
    ../../modules/home/git.nix
    ../../modules/home/neovim
    ../../modules/home/opencode
    ../../modules/home/opencode/darwin.nix
    ../../modules/home/starship
    ../../modules/home/vicinae
    ../../modules/home/zoxide
    ../../modules/home/zen-browser
    ../../modules/home/zsh
    ../../modules/home/anytype
    ./aerospace.nix
  ];

  home = {
    username = "kosciak";
    homeDirectory = "/Users/kosciak";
    stateVersion = "26.05";
  };
  programs = {
    home-manager.enable = true;
    zen-browser = {
      enable = true;
      package = null;
      profileName = "wave";
      installId = "6ED35B3CA1B5D3AF";
      settings = (import ../../modules/home/zen-browser/config/settings.nix) // {
        "browser.startup.homepage" = "https://development-caddy.localhost";
        "browser.startup.page" = 1;
      };
    };
    ghostty.settings = {
      macos-titlebar-style = "hidden";
      macos-icon = "custom";
      macos-custom-icon = "~/.config/secrets/kanagawa-wave-ghostty.icns";
    };
  };
  xdg.enable = true;
}
