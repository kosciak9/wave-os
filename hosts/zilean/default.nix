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
    tmpfiles.rules = [
      "f /var/lib/wave-os/ssh/kosciak 0644 root root - -"
      # The headless host cannot reach its BIOS, which overclocks the CPU to 4.3 GHz all-core;
      # uncorrected L1 machine checks reset it, so cap it at the 3.5 GHz base clock.
      "w /sys/devices/system/cpu/intel_pstate/no_turbo - - - - 1"
    ];
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
      # Quieter Smart Fan IV curves on the CPU (PECI) temperature; the chip keeps applying them
      # if the OS hangs. Lowest points stay above the measured stall PWM: 35 for fans 1-2, 70 for fan 4.
      fan-curves = {
        description = "Quiet motherboard fan curves";
        wantedBy = [ "multi-user.target" ];
        after = [ "systemd-modules-load.service" ];
        serviceConfig.Type = "oneshot";
        script = ''
          hwmon=$(echo /sys/devices/platform/nct6775.*/hwmon/hwmon*)
          curve() {
            fan=$1 start=$2
            shift 2
            point=1
            for spec in "$@"; do
              echo $((''${spec%/*} * 1000)) >"$hwmon/pwm''${fan}_auto_point''${point}_temp"
              echo "''${spec#*/}" >"$hwmon/pwm''${fan}_auto_point''${point}_pwm"
              point=$((point + 1))
            done
            echo "$start" >"$hwmon/pwm''${fan}_start"
            echo 7 >"$hwmon/pwm''${fan}_temp_sel"
            echo 5 >"$hwmon/pwm''${fan}_enable"
          }
          curve 1 80 50/45 60/70 70/127 80/191 90/255
          curve 2 80 50/45 60/70 70/127 80/191 90/255
          curve 4 130 50/95 60/115 70/150 80/200 90/255
        '';
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
    # Daily short and monthly long self-tests; the 4 TB disk needs about 8 hours for the long one,
    # so it starts at 01:00 to finish before the working day.
    smartd = {
      enable = true;
      defaults.monitored = "-a -o on -S on -W 0,50,55 -s (S/../.././02|L/../01/./01)";
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
