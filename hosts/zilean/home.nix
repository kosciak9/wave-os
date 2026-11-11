{ pkgs, ... }:

{
  imports = [
    ../../modules/home/agents
    ../../modules/home/alfred
    ../../modules/home/anytype
    ../../modules/home/camofox/linux.nix
    ../../modules/home/cli
    ../../modules/home/devenv
    ../../modules/home/frida
    ../../modules/home/git.nix
    ../../modules/home/lightpanda
    ../../modules/home/neovim
    ../../modules/home/opencode
    ../../modules/home/slack-mirror
    ../../modules/home/starship
    ../../modules/home/t3code
    ../../modules/home/whisper/linux.nix
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

  services = {
    alfred.enable = true;
    camofox.vnc.enable = true;
    frida.enable = false;
    slack-mirror = {
      enable = true;
      sync.enable = true;
    };
  };

  programs = {
    home-manager.enable = true;
    password-store.enable = true;
    agents.cua.enable = false;
  };

  xdg.enable = true;
}
