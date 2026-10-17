{ pkgs, ... }:

{
  imports = [
    ./hardware.nix
    ../../modules/wave/nixos.nix
    ../../modules/sops.nix
  ];

  boot.loader = {
    systemd-boot = {
      enable = true;
      configurationLimit = 10;
    };
    efi.canTouchEfiVariables = true;
    timeout = 3;
  };

  networking = {
    hostName = "zilean";
    useDHCP = false;
    useNetworkd = true;
    firewall.interfaces = {
      enp4s0 = {
        allowedTCPPorts = [ 22 ];
        allowedUDPPortRanges = [
          {
            from = 60000;
            to = 61000;
          }
        ];
      };
      tailscale0 = {
        allowedTCPPorts = [ 22 ];
        allowedUDPPortRanges = [
          {
            from = 60000;
            to = 61000;
          }
        ];
      };
    };
  };
  systemd.network.networks."10-ethernet" = {
    matchConfig.Name = "enp4s0";
    networkConfig.DHCP = "yes";
    linkConfig.RequiredForOnline = "routable";
  };

  time.timeZone = "Europe/Warsaw";
  i18n.defaultLocale = "en_US.UTF-8";
  console.keyMap = "pl2";

  users.users = {
    kosciak = {
      isNormalUser = true;
      uid = 1000;
      linger = true;
      shell = pkgs.zsh;
      extraGroups = [ "wheel" ];
      hashedPassword = "!";
    };
    root.hashedPassword = "!";
  };
  security.sudo.wheelNeedsPassword = false;

  sops.secrets = {
    "cliproxyapi/api-key".owner = "kosciak";
    "cliproxyapi/base-url".owner = "kosciak";
  };

  virtualisation.podman.enable = true;

  wave.deployTarget.enable = true;

  services = {
    resolved.enable = true;
    openssh = {
      enable = true;
      openFirewall = false;
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
      };
    };
    avahi = {
      enable = true;
      openFirewall = true;
      publish = {
        enable = true;
        addresses = true;
      };
    };
    tailscale = {
      enable = true;
      extraSetFlags = [ "--operator=kosciak" ];
    };
    fstrim.enable = true;
    smartd.enable = true;
  };
  systemd.tmpfiles.rules = [ "f /var/lib/wave-os/ssh/kosciak 0644 root root - -" ];

  hardware = {
    enableRedistributableFirmware = true;
    graphics.enable = true;
  };
  zramSwap = {
    enable = true;
    memoryPercent = 25;
  };

  programs = {
    git.enable = true;
    tmux.enable = true;
    zsh = {
      enable = true;
      enableGlobalCompInit = false;
    };
    gnupg.agent = {
      enable = true;
      pinentryPackage = pkgs.pinentry-curses;
    };
  };
  environment.systemPackages = with pkgs; [
    bubblewrap
    curl
    e2fsprogs
    gnupg
    podman-compose
    vncdotool
    (runCommand "bcache-zsh-completions" { nativeBuildInputs = [ installShellFiles ]; } ''
      installShellCompletion --cmd bcache --zsh ${../../packages/bcache-completions.zsh}
    '')
  ];

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    extra-substituters = [ "https://wave-os.cachix.org" ];
    extra-trusted-public-keys = [ "wave-os.cachix.org-1:cwQ73uY7ZSe7Rqb8jWzu2/fYWXfe0An7DjsSPXNVgRw=" ];
  };
  system.stateVersion = "26.11";
}
