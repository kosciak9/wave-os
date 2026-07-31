{
  imports = [
    ../../modules/home/cli
    ../../modules/home/devenv
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
    };
    ghostty.settings = {
      macos-titlebar-style = "hidden";
      macos-icon = "custom";
      macos-custom-icon = "~/.config/secrets/kanagawa-wave-ghostty.icns";
    };
  };
  xdg.enable = true;
}
