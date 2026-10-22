{ config, pkgs, ... }:

{
  imports = [
    ./hardware.nix
    ../../modules/wave/nixos.nix
    ../../modules/sops.nix
    ../../modules/monitoring/nixos.nix
    ../../modules/monitoring/processes.nix
    ../../modules/monitoring/server.nix
  ];

  boot = {
    loader = {
      systemd-boot = {
        enable = true;
        configurationLimit = 10;
        # Headless: a generation that does not boot to remote access falls back to the previous one.
        bootCounting = {
          enable = true;
          tries = 2;
        };
      };
      efi.canTouchEfiVariables = true;
      timeout = 3;
    };
    # Without a console, emergency mode would hang the boot; reboot so boot counting can fall back.
    initrd.systemd.services.emergency = {
      overrideStrategy = "asDropin";
      serviceConfig.ExecStart = [
        ""
        "${config.boot.initrd.systemd.package}/bin/systemctl --no-block reboot"
      ];
    };
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
  systemd = {
    network.networks."10-ethernet" = {
      matchConfig.Name = "enp4s0";
      networkConfig.DHCP = "yes";
      linkConfig.RequiredForOnline = "routable";
    };
    # A boot counts as good only once the host is reachable again.
    targets.boot-complete = {
      requires = [
        "sshd.service"
        "tailscaled.service"
      ];
      after = [
        "sshd.service"
        "tailscaled.service"
      ];
    };
    services.emergency = {
      overrideStrategy = "asDropin";
      serviceConfig.ExecStart = [
        ""
        "${config.systemd.package}/bin/systemctl --no-block reboot"
      ];
    };
    tmpfiles.rules = [ "f /var/lib/wave-os/ssh/kosciak 0644 root root - -" ];
    # Builds, agents and containers may exhaust memory; they get throttled or killed, not the host.
    services = {
      nix-daemon.serviceConfig = {
        MemoryHigh = "9G";
        MemoryMax = "11G";
      };
      sshd.serviceConfig = {
        MemoryMin = "64M";
        ManagedOOMPreference = "omit";
      };
      tailscaled.serviceConfig = {
        MemoryMin = "64M";
        ManagedOOMPreference = "omit";
      };
    };
    slices = {
      "-".sliceConfig = {
        ManagedOOMSwap = "kill";
        ManagedOOMMemoryPressureLimit = "60%";
      };
      system.sliceConfig.ManagedOOMMemoryPressureLimit = "60%";
      user.sliceConfig.ManagedOOMMemoryPressureLimit = "60%";
    };
  };
  systemd.oomd = {
    enableRootSlice = true;
    enableSystemSlice = true;
    enableUserSlices = true;
    settings.OOM.DefaultMemoryPressureDurationSec = "30s";
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
    # Daily short and monthly long self-tests; the 4 TB disk needs about 8 hours for the long one.
    smartd = {
      enable = true;
      defaults.monitored = "-a -o on -S on -W 0,50,55 -s (S/../.././02|L/../01/./03)";
    };
    btrfs.autoScrub.enable = true;
  };
  hardware = {
    enableRedistributableFirmware = true;
    graphics.enable = true;
  };
  zramSwap = {
    enable = true;
    memoryPercent = 25;
  };
  # Second tier behind zram for long builds; btrfs gets a NOCOW swapfile.
  swapDevices = [
    {
      device = "/var/lib/swapfile";
      size = 8 * 1024;
    }
  ];

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
    max-jobs = 2;
    extra-substituters = [ "https://wave-os.cachix.org" ];
    extra-trusted-public-keys = [ "wave-os.cachix.org-1:cwQ73uY7ZSe7Rqb8jWzu2/fYWXfe0An7DjsSPXNVgRw=" ];
  };
  system.stateVersion = "26.11";
}
