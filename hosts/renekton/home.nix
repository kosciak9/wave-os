{
  imports = [
    ../../modules/home/devenv
    ../../modules/home/ghostty
    ../../modules/home/git.nix
    ../../modules/home/neovim
    ../../modules/home/opencode
    ../../modules/home/starship
    ../../modules/home/zsh
    ./aerospace.nix
  ];

  home = {
    username = "kosciak";
    homeDirectory = "/Users/kosciak";
    stateVersion = "26.05";
  };
  programs.home-manager.enable = true;
  programs.ghostty.settings = {
    macos-titlebar-style = "hidden";
    macos-icon = "custom";
    macos-custom-icon = "~/.config/secrets/kanagawa-wave-ghostty.icns";
  };
  xdg.enable = true;
}
