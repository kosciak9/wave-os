{ pkgs, ... }:

{
  system = {
    primaryUser = "kosciak";
    stateVersion = 1;

    defaults = {
      dock = {
        show-process-indicators = true;
        show-recents = true;
        wvous-tl-corner = 2; # Mission Control
        wvous-tr-corner = 1; # Disabled
        wvous-bl-corner = 1; # Disabled
        wvous-br-corner = 1; # Disabled
      };

      NSGlobalDomain = {
        AppleInterfaceStyle = "Dark";
      };

      CustomUserPreferences = {
        NSGlobalDomain = {
          AppleAccentColor = 1; # Orange
          AppleAquaColorVariant = 1;
        };

        "com.apple.dock" = {
          show-recents-count = 1;
        };
      };
    };
  };

  networking = {
    hostName = "renekton";
    localHostName = "renekton";
    computerName = "renekton";
  };

  users.users.kosciak = {
    name = "kosciak";
    home = "/Users/kosciak";
  };

  nixpkgs.config.allowUnfree = true;
  nixpkgs.overlays = [
    (final: _prev: {
      opencode = final.callPackage ../../packages/opencode-darwin.nix { };
    })
  ];

  environment.systemPackages = with pkgs; [
    bat
    delta
    difftastic
    eza
    fd
    gh
    httpie
    neovide
    neovim
    nodejs
    opencode
    fzf
    git
    gnupg
    infisical
    pass
    pinentry_mac
    podman
    ripgrep
    starship
    syncthing-macos
    tailscale
    tree-sitter
    (callPackage ../../packages/weave.nix { })
    zoxide
    zsh
    yadm
    tmux
  ];

  fonts.packages = [
    pkgs.overpass
    pkgs.nerd-fonts.overpass
    pkgs.noto-fonts
    pkgs.noto-fonts-color-emoji
  ];

  services.tailscale.enable = true;

  determinateNix.enable = true;
}
