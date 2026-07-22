{
  imports = [
    ../../modules/home/git.nix
    ../../modules/home/neovim
    ../../modules/home/starship
    ./aerospace.nix
  ];

  home.username = "kosciak";
  home.homeDirectory = "/Users/kosciak";
  home.stateVersion = "26.05";
  programs.home-manager.enable = true;
  xdg.enable = true;
}
