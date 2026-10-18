{ pkgs, ... }:

{
  imports = [
    ../../modules/home/agents
    ../../modules/home/camofox/linux.nix
    ../../modules/home/cli
    ../../modules/home/devenv
    ../../modules/home/git.nix
    ../../modules/home/neovim
    ../../modules/home/opencode
    ../../modules/home/starship
    ../../modules/home/t3code
    ../../modules/home/zoxide
    ../../modules/home/zsh
    ../../modules/home/zsh/linux.nix
  ];

  home = {
    username = "kosciak";
    homeDirectory = "/home/kosciak";
    stateVersion = "26.11";
    sessionPath = [
      "$HOME/.cargo/bin"
      "$HOME/.local/bin"
    ];
    packages = with pkgs; [
      fd
      jq
      nodejs
      ripgrep
      tesseract
      trash-cli
    ];
  };

  programs = {
    home-manager.enable = true;
    password-store.enable = true;
    agents.cua.enable = false;
  };

  xdg.enable = true;
}
