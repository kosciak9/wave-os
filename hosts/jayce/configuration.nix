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
    geoclue2 = {
      enable = true;
      enableDemoAgent = true;
      enableNmea = false;
      enable3G = false;
      enableCDMA = false;
      enableModemGPS = false;
      enableWifi = true;
      geoProviderUrl = "https://api.beacondb.net/v1/geolocate";
      submitData = true;
      submissionUrl = "https://api.beacondb.net/v2/geosubmit";
      submissionNick = "wave-client";
      appConfig.geoclue-where-am-i = {
        desktopID = "geoclue-where-am-i";
        isAllowed = true;
        isSystem = false;
      };
    };
    gnome.gnome-keyring.enable = true;
    logind.settings.Login = {
      HandleLidSwitch = "suspend";
      HandleLidSwitchDocked = "suspend";
      HandleLidSwitchExternalPower = "suspend";
    };
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
      xwayland.enable = true;
      package = pkgs.hyprland.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ../../patches/hyprland-niri-parity.patch ];
      });
    };
    zsh = {
      enable = true;
      enableGlobalCompInit = false;
    };
  };

  systemd.services.wave-blackout-before-sleep = {
    description = "Trigger Wave OS blackout before sleep";
    wantedBy = [ "sleep.target" ];
    before = [ "sleep.target" ];
    serviceConfig.Type = "oneshot";
    script = ''
      ${pkgs.systemd}/bin/systemctl --user --machine=kosciak@.host start wave-blackout.service || true
      ${pkgs.coreutils}/bin/sleep 0.08
    '';
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
