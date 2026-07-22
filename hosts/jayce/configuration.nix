{ pkgs, ... }:

{
  imports = [ ./hardware-configuration.nix ];

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
  nixpkgs.config.allowUnfree = true;

  boot = {
    kernelPackages = pkgs.linuxPackages_latest;
    kernelParams = [ "quiet" ];
    consoleLogLevel = 3;
    loader = {
      systemd-boot = {
        enable = true;
        configurationLimit = 10;
      };
      efi.canTouchEfiVariables = true;
    };
    plymouth.enable = true;
  };

  networking = {
    hostName = "jayce";
    networkmanager = {
      enable = true;
      wifi.powersave = false;
    };
  };

  time.timeZone = "Europe/Warsaw";
  i18n = {
    defaultLocale = "en_US.UTF-8";
    extraLocaleSettings = {
      LC_ADDRESS = "pl_PL.UTF-8";
      LC_IDENTIFICATION = "pl_PL.UTF-8";
      LC_MEASUREMENT = "pl_PL.UTF-8";
      LC_MONETARY = "pl_PL.UTF-8";
      LC_NAME = "pl_PL.UTF-8";
      LC_NUMERIC = "pl_PL.UTF-8";
      LC_PAPER = "pl_PL.UTF-8";
      LC_TELEPHONE = "pl_PL.UTF-8";
      LC_TIME = "pl_PL.UTF-8";
    };
  };
  console.keyMap = "pl2";
  services.xserver.xkb.layout = "pl";

  hardware = {
    bluetooth = {
      enable = true;
      powerOnBoot = true;
    };
    enableRedistributableFirmware = true;
    graphics.enable = true;
  };

  services = {
    displayManager = {
      defaultSession = "hyprland-uwsm";
      gdm.enable = true;
    };
    flatpak.enable = true;
    fprintd.enable = true;
    gnome.gnome-keyring.enable = true;
    power-profiles-daemon.enable = true;
    upower.enable = true;
    tailscale.enable = true;
    syncthing = {
      enable = true;
      user = "kosciak";
      group = "users";
      dataDir = "/home/kosciak";
      configDir = "/home/kosciak/.config/syncthing";
      openDefaultPorts = true;
    };
    pipewire = {
      enable = true;
      audio.enable = true;
      alsa = {
        enable = true;
        support32Bit = true;
      };
      pulse.enable = true;
    };
  };

  programs = {
    fuse.enable = true;
    gnupg.agent = {
      enable = true;
    };
    hyprland = {
      enable = true;
      withUWSM = true;
      package = pkgs.hyprland.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ../../patches/hyprland-niri-parity.patch ];
      });
    };
    zsh = {
      enable = true;
      enableGlobalCompInit = false;
    };
  };

  security = {
    polkit.enable = true;
    rtkit.enable = true;
  };

  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
    config.common.default = [
      "hyprland"
      "gtk"
    ];
  };

  zramSwap = {
    enable = true;
    memoryPercent = 25;
  };

  users.users.kosciak = {
    isNormalUser = true;
    description = "Franek Madej";
    shell = pkgs.zsh;
    extraGroups = [
      "audio"
      "networkmanager"
      "video"
      "wheel"
    ];
  };

  environment = {
    sessionVariables.NIXOS_OZONE_WL = "1";
    systemPackages = with pkgs; [
      git
      gnupg
      pinentry-gnome3
      vim
      wget
    ];
  };

  system.stateVersion = "26.05";
}
