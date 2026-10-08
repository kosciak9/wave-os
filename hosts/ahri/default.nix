{ modulesPath, pkgs, ... }:

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
    firewall.interfaces = {
      end0.allowedTCPPorts = [ 22 ];
      eth0.allowedTCPPorts = [ 22 ];
      tailscale0.allowedTCPPorts = [ 22 ];
    };
  };
  time.timeZone = "Europe/Warsaw";

  users.users.kosciak = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    hashedPassword = "!";
  };
  users.users.root.hashedPassword = "!";
  security.sudo.wheelNeedsPassword = false;

  wave.deployTarget.enable = true;

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
      Storage=volatile
      RuntimeMaxUse=32M
      RuntimeKeepFree=64M
      MaxRetentionSec=1day
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
    ];
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
      max-jobs = 1;
      cores = 1;
      keep-outputs = false;
      keep-derivations = false;
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
    };
  };

  environment.systemPackages = with pkgs; [
    beamMinimalPackages.elixir
    beamMinimalPackages.erlang
    curl
  ];
  documentation = {
    enable = false;
    nixos.enable = false;
  };
  system.stateVersion = "26.05";
}
