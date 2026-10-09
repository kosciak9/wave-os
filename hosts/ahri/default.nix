{
  inputs,
  lib,
  modulesPath,
  pkgs,
  ...
}:

let
  # GNU ld rejects the debug and unwind sections of Zig's bundled compiler_rt on aarch64.
  herdr = inputs.herdr.packages.${pkgs.stdenv.hostPlatform.system}.default.overrideAttrs (old: {
    nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.lld ];
    env = old.env // {
      RUSTFLAGS = "-C link-arg=-fuse-ld=lld";
    };
  });
in
{
  imports = [
    ./hardware.nix
    ./health.nix
    ../../modules/wave/nixos.nix
    "${modulesPath}/profiles/all-hardware.nix"
  ];

  networking = {
    hostName = "ahri";
    useDHCP = false;
    useNetworkd = true;
    firewall.interfaces =
      lib.genAttrs
        [
          "end0"
          "eth0"
          "tailscale0"
        ]
        (_: {
          allowedTCPPorts = [ 22 ];
          allowedUDPPortRanges = [
            {
              from = 60000;
              to = 61000;
            }
          ];
        });
  };
  time.timeZone = "Europe/Warsaw";

  users.users.kosciak = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    hashedPassword = "!";
    # Keeps the Herdr server reachable by the renekton coordinator without a login.
    linger = true;
  };
  users.users.root.hashedPassword = "!";
  security.sudo.wheelNeedsPassword = false;

  wave = {
    deployTarget.enable = true;
    deployer.enable = true;
    autoDeploy = {
      enable = true;
      nodes = [ "renekton" ];
    };
  };

  services = {
    resolved.enable = true;
    openssh = {
      enable = true;
      openFirewall = false;
      authorizedKeysFiles = [ "/var/lib/wave/ssh/%u" ];
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
      };
    };
    tailscale.enable = true;

    caddy = {
      enable = true;
      globalConfig = ''
        admin off
        auto_https off
      '';
      virtualHosts."http://127.0.0.1:8080".extraConfig = ''
        bind 127.0.0.1
        respond /healthz "ahri bootstrap" 200
        respond 404
      '';
    };

    journald.extraConfig = ''
      Storage=persistent
      SystemMaxUse=256M
      SystemKeepFree=1G
      MaxRetentionSec=14day
      RateLimitIntervalSec=30s
      RateLimitBurst=1000
      ForwardToSyslog=no
    '';
  };

  boot.tmp = {
    useTmpfs = true;
    tmpfsSize = "256M";
  };
  fileSystems."/var/tmp" = {
    device = "tmpfs";
    fsType = "tmpfs";
    options = [
      "mode=1777"
      "size=128M"
      "nosuid"
      "nodev"
    ];
  };
  zramSwap = {
    enable = true;
    memoryPercent = 25;
  };
  swapDevices = [ ];

  systemd = {
    network.networks."10-ethernet" = {
      matchConfig.Name = "end0 eth0";
      networkConfig.DHCP = "ipv4";
      linkConfig.RequiredForOnline = "routable";
    };
    # sshd reads authorized keys as the login user; these are public keys.
    tmpfiles.rules = [
      "d /var/lib/wave 0755 root root -"
      "d /var/lib/wave/ssh 0755 root root -"
      "f /var/lib/wave/ssh/kosciak 0644 root root -"
      "d /home/kosciak/.config 0755 kosciak users -"
      "d /home/kosciak/.config/herdr 0700 kosciak users -"
      # renekton pins this install identity in its saved-machine federation policy.
      ''f+ /home/kosciak/.config/herdr/machine.json 0600 kosciak users - {"machine_id": "machine_9026bebb6184fc9965a24b867836dce9"}''
    ];
    user.services.herdr = {
      description = "Herdr default session";
      wantedBy = [ "default.target" ];
      restartTriggers = [ herdr ];
      unitConfig.ConditionUser = "kosciak";
      environment.SHELL = "${pkgs.bashInteractive}/bin/bash";
      path = [ "/run/current-system/sw" ];
      serviceConfig = {
        ExecStartPre = "-${lib.getExe herdr} --session default server stop";
        ExecStart = "${lib.getExe herdr} --session default server";
        ExecStop = "${lib.getExe herdr} --session default server stop";
        Restart = "on-failure";
        RestartSec = 3;
        KillSignal = "SIGINT";
        KillMode = "mixed";
        TimeoutStopSec = 30;
      };
    };
    coredump.settings.Coredump = {
      Storage = "none";
      ProcessSizeMax = 0;
    };
  };

  nix = {
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      extra-substituters = [ "https://wave-os.cachix.org" ];
      extra-trusted-public-keys = [ "wave-os.cachix.org-1:cwQ73uY7ZSe7Rqb8jWzu2/fYWXfe0An7DjsSPXNVgRw=" ];
      max-jobs = 1;
      cores = 2;
      keep-outputs = false;
      keep-derivations = false;
    };
  };

  environment.systemPackages = [
    herdr
  ]
  ++ (with pkgs; [
    beamMinimalPackages.elixir
    beamMinimalPackages.erlang
    curl
    opencode
  ]);
  documentation = {
    enable = false;
    nixos.enable = false;
  };
  system.stateVersion = "26.05";
}
