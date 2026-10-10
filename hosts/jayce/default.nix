{ options, pkgs, ... }:

let
  wavePowerProfilePolicy = pkgs.writeScriptBin "wave-power-profile-policy" ''
    #!${pkgs.python3.withPackages (pythonPackages: [ pythonPackages.dbus-next ])}/bin/python3
    ${builtins.readFile ./scripts/power-profile-policy.py}
  '';
in

{
  imports = [
    ../../modules/wave/nixos.nix
    ../../modules/sops.nix
    ../../modules/caddy/linux.nix
    ./hardware.nix
    ./user.nix
  ];

  nix = {
    settings.experimental-features = [
      "nix-command"
      "flakes"
    ];
  };
  nixpkgs.config.allowUnfree = true;

  # The Home Manager services read these through osConfig.
  sops.secrets."pimalaya/google-client.json".owner = "kosciak";

  boot = {
    kernelPackages = pkgs.linuxPackages;
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
    # DHCP and DNS from libvirt's default NAT network.
    firewall.interfaces.virbr0 = {
      allowedUDPPorts = [
        53
        67
      ];
      allowedTCPPorts = [ 53 ];
    };
    firewall.interfaces.tailscale0 = {
      allowedTCPPorts = [ 22 ];
      allowedUDPPortRanges = [
        {
          from = 60000;
          to = 61000;
        }
      ];
    };
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

  wave.deployer.enable = true;

  services = {
    openssh = {
      enable = true;
      openFirewall = false;
      settings.KexAlgorithms = [ "+ecdh-sha2-nistp256" ];
      settings.Macs = (options.services.openssh.settings.type.getSubOptions [ ]).Macs.default ++ [
        "hmac-sha2-256"
      ];
    };
    avahi = {
      enable = true;
      nssmdns4 = true;
      openFirewall = true;
    };
    udev.extraRules = ''
      SUBSYSTEM=="hidraw", ATTRS{idVendor}=="32ac", TAG+="uaccess"
    '';
    xserver.xkb.layout = "pl";
    displayManager = {
      defaultSession = "hyprland-uwsm";
      gdm.enable = true;
    };
    flatpak.enable = true;
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
      HandleLidSwitch = "suspend-then-hibernate";
      HandleLidSwitchDocked = "suspend-then-hibernate";
      HandleLidSwitchExternalPower = "suspend-then-hibernate";
    };
    power-profiles-daemon.enable = true;
    printing.enable = true;
    upower = {
      enable = true;
      percentageLow = 20;
      percentageCritical = 10;
      percentageAction = 5;
      criticalPowerAction = "Hibernate";
    };
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

  systemd = {
    sleep.settings.Sleep = {
      HibernateDelaySec = "1h";
      HibernateOnACPower = false;
    };
    services = {
      # Keep hibernation storage out of root snapshots; prepare this subvolume
      # before activation, rather than silently creating a normal directory.
      mkswap-swap-swapfile.serviceConfig.ExecCondition = "${pkgs.btrfs-progs}/bin/btrfs subvolume show /swap";

      wave-blackout-before-sleep = {
        description = "Trigger Wave OS blackout before sleep";
        wantedBy = [ "sleep.target" ];
        before = [ "sleep.target" ];
        serviceConfig.Type = "oneshot";
        script = ''
          ${pkgs.systemd}/bin/systemctl --user --machine=kosciak@.host start wave-blackout.service || true
          ${pkgs.coreutils}/bin/sleep 0.08
        '';
      };

      wave-power-profile-policy = {
        description = "Select performance on AC or with caffeinate, otherwise save battery power";
        # The daemon units pull this policy in and restart it after PartOf stops it;
        # keep it out of multi-user.target to avoid an ordering cycle.
        wantedBy = [
          "power-profiles-daemon.service"
          "upower.service"
        ];
        wants = [
          "power-profiles-daemon.service"
          "upower.service"
        ];
        after = [
          "dbus.service"
          "systemd-logind.service"
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
    };
  };

  virtualisation = {
    podman.enable = true;
    libvirtd = {
      enable = true;
      # Guests start only on request, also after a host reboot.
      onBoot = "ignore";
      onShutdown = "shutdown";
      qemu = {
        runAsRoot = false;
        swtpm.enable = true;
        vhostUserPackages = [ pkgs.virtiofsd ];
      };
    };
  };

  programs = {
    virt-manager.enable = true;
    obs-studio = {
      enable = true;
      enableVirtualCamera = true;
      plugins = with pkgs.obs-studio-plugins; [
        obs-pipewire-audio-capture
        obs-wayland-hotkeys
      ];
    };
    nix-ld.enable = true;
    fuse.enable = true;
    gnupg.agent = {
      enable = true;
    };
    hyprland = {
      enable = true;
      withUWSM = true;
      xwayland.enable = true;
      package = pkgs.wave-hyprland;
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

  environment = {
    sessionVariables.NIXOS_OZONE_WL = "1";
    # virsh defaults to the per-user session; VMs live in the system instance.
    variables.LIBVIRT_DEFAULT_URI = "qemu:///system";
    systemPackages = with pkgs; [
      e2fsprogs
      gnupg
      pinentry-gnome3
      podman-compose
      qmk_hid
      virt-viewer
      vncdotool
    ];
  };

  # Install the standard proportional Overpass family system-wide; the
  # Nerd Font variant in Home Manager provides the terminal-focused fonts.
  fonts.packages = [ pkgs.overpass ];

  system.stateVersion = "26.05";
}
