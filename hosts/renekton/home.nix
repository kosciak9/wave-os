{
  imports = [
    ../../modules/home/devenv
    ../../modules/home/git.nix
    ../../modules/home/neovim
    ../../modules/home/starship
    ./aerospace.nix
  ];

  home = {
    username = "kosciak";
    homeDirectory = "/Users/kosciak";
    stateVersion = "26.05";
  };
  programs.home-manager.enable = true;
  xdg.enable = true;
}
