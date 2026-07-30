{ pkgs, ... }:

let
  wavePowerProfilePolicy = pkgs.writeScriptBin "wave-power-profile-policy" ''
    #!${pkgs.python3.withPackages (pythonPackages: [ pythonPackages.dbus-next ])}/bin/python3
    ${builtins.readFile ./scripts/power-profile-policy.py}
  '';
in

{
  imports = [
    ../../modules/caddy/linux.nix
    ./hardware.nix
  ];

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
    kernel.sysctl = {
      "vm.dirty_writeback_centisecs" = 6000;
      "vm.laptop_mode" = 5;
    };
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

  hardware = {
    bluetooth = {
      enable = true;
      powerOnBoot = true;
    };
    enableRedistributableFirmware = true;
    graphics.enable = true;
  };

  services = {
    udev.extraRules = ''
      SUBSYSTEM=="hidraw", ATTRS{idVendor}=="32ac", TAG+="uaccess"
    '';
    xserver.xkb.layout = "pl";
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

  systemd.services.wave-power-profile-policy = {
    description = "Select the power profile based on AC power state";
    # The daemon units also pull this policy back in after PartOf stops it on
    # their restart; no after=multi-user.target cycle is introduced.
    wantedBy = [
      "multi-user.target"
      "power-profiles-daemon.service"
      "upower.service"
    ];
    wants = [
      "power-profiles-daemon.service"
      "upower.service"
    ];
    after = [
      "dbus.service"
      "power-profiles-daemon.service"
      "upower.service"
    ];
    partOf = [
      "power-profiles-daemon.service"
      "upower.service"
    ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${wavePowerProfilePolicy}/bin/wave-power-profile-policy";
      Restart = "on-failure";
      RestartSec = 5;
      User = "root";
      Group = "root";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      RestrictAddressFamilies = [ "AF_UNIX" ];
      CapabilityBoundingSet = "";
    };
  };

  virtualisation.podman.enable = true;

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
        patches = (old.patches or [ ]) ++ [ ./desktop/hyprland-niri-parity.patch ];
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
    pam.services.hyprlock = { };
    polkit.enable = true;
    rtkit.enable = true;
  };

  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
    config.common = {
      default = [
        "hyprland"
        "gtk"
      ];
      "org.freedesktop.impl.portal.ScreenCast" = [ "hyprland" ];
      "org.freedesktop.impl.portal.Screenshot" = [ "hyprland" ];
      "org.freedesktop.impl.portal.GlobalShortcuts" = [ "hyprland" ];
      "org.freedesktop.impl.portal.FileChooser" = [ "gtk" ];
      "org.freedesktop.impl.portal.Access" = [ "gtk" ];
      "org.freedesktop.impl.portal.Notification" = [ "gtk" ];
      "org.freedesktop.impl.portal.Secret" = [ "gnome-keyring" ];
    };
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
      podman-compose
      qmk_hid
      vim
      wget
    ];
  };

  # Install the standard proportional Overpass family system-wide; the
  # Nerd Font variant in Home Manager provides the terminal-focused fonts.
  fonts.packages = [ pkgs.overpass ];

  system.stateVersion = "26.05";
}
