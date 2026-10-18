{
  config,
  lib,
  modulesPath,
  pkgs,
  ...
}:
let
  # The Pi firmware loads the kernel itself; with U-Boot in between, this board never reached Linux.
  # Files are named by store hash so an unchanged kernel or initrd is not rewritten, and the
  # config.txt rename is the single switch point between generations.
  installFirmware = ''
    store_id() {
      local path
      path=$(readlink -f "$1")
      path=''${path#/nix/store/}
      echo "''${path%%-*}"
    }
    install_firmware() {
      local dir=$1 system kernel initrd dtb cmdline file
      system=$(readlink -f "$2")
      kernel=nixos/$(store_id "$system/kernel")-zImage
      initrd=nixos/$(store_id "$system/initrd")-initrd
      dtb=nixos/$(store_id "$system/dtbs/bcm2836-rpi-2-b.dtb")-bcm2836-rpi-2-b.dtb
      cmdline=nixos/$(basename "$system" | cut -d- -f1)-cmdline.txt
      mkdir -p "$dir/nixos"
      copy() {
        [[ -e $dir/$2 ]] && return
        cp "$1" "$dir/$2.tmp"
        mv "$dir/$2.tmp" "$dir/$2"
      }
      copy "$system/kernel" "$kernel"
      copy "$system/initrd" "$initrd"
      copy "$system/dtbs/bcm2836-rpi-2-b.dtb" "$dtb"
      echo "init=$system/init $(cat "$system/kernel-params")" >"$dir/$cmdline"
      cat >"$dir/config.txt.tmp" <<EOF
    avoid_warnings=1
    enable_uart=1
    kernel=$kernel
    initramfs $initrd followkernel
    device_tree=$dtb
    cmdline=$cmdline
    EOF
      sync
      mv "$dir/config.txt.tmp" "$dir/config.txt"
      for file in "$dir"/nixos/*; do
        case ''${file#"$dir"/} in
          "$kernel" | "$initrd" | "$dtb" | "$cmdline") ;;
          *) rm -f "$file" ;;
        esac
      done
      sync
    }
  '';
in
{
  imports = [
    "${modulesPath}/profiles/base.nix"
    "${modulesPath}/installer/sd-card/sd-image.nix"
    ../../modules/wave/nixos.nix
  ];

  networking = {
    hostName = "zac";
    useDHCP = false;
    useNetworkd = true;
    wireless = {
      enable = true;
      userControlled = true;
      allowAuxiliaryImperativeNetworks = true;
      scanOnLowSignal = false;
    };
    firewall = {
      allowedUDPPorts = [ 5353 ];
      # sendspin queries mDNS from an ephemeral port, so the Music Assistant server answers
      # with unicast from port 5353; without this the receiver never finds a server.
      extraCommands = ''
        ip46tables -A nixos-fw -p udp --sport 5353 -j nixos-fw-accept
      '';
    };
  };
  systemd.network = {
    # The receiver normally runs on Wi-Fi alone, with Ethernet unplugged.
    wait-online.anyInterface = true;
    networks = {
      "10-ethernet" = {
        # The Pi 2 Ethernet sits on USB, so its name is path-based (enu1u1), not end0.
        matchConfig.Type = "ether";
        networkConfig = {
          DHCP = "ipv4";
          MulticastDNS = true;
        };
      };
      "20-wifi" = {
        matchConfig.Name = "wl*";
        networkConfig = {
          DHCP = "ipv4";
          MulticastDNS = true;
        };
      };
    };
  };
  time.timeZone = "Europe/Warsaw";

  users.users = {
    kosciak = {
      isNormalUser = true;
      extraGroups = [
        "wheel"
        "wpa_supplicant"
      ];
      hashedPassword = "!";
    };
    root.hashedPassword = "!";
  };
  security.sudo.wheelNeedsPassword = false;
  wave.deployTarget.enable = true;

  services = {
    resolved = {
      enable = true;
      settings.Resolve.MulticastDNS = true;
    };
    openssh = {
      enable = true;
      authorizedKeysFiles = [ "/var/lib/wave-os/ssh/%u" ];
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
      };
    };
    tailscale.enable = true;
    # Without a console, logs from a failed boot are only readable from the card afterwards.
    journald.settings.Journal = {
      Storage = "persistent";
      SystemMaxUse = "32M";
    };
  };

  hardware = {
    enableRedistributableFirmware = lib.mkForce false;
    firmware = [
      (pkgs.runCommand "rt5370-firmware" { } ''
        install -Dm644 ${pkgs.linux-firmware}/lib/firmware/rt2870.bin \
          $out/lib/firmware/rt2870.bin
      '')
    ];
  };
  boot = {
    kernelPackages = pkgs.linuxPackages_latest;
    kernelParams = [
      "console=ttyAMA0,115200n8"
      "console=tty0"
    ];
    kernelModules = [
      "rt2800usb"
      "snd_usb_audio"
    ];
    supportedFilesystems = lib.mkForce [
      "ext4"
      "vfat"
    ];
    loader = {
      external = {
        enable = true;
        installHook = pkgs.writeShellScript "install-firmware-boot" ''
          set -euo pipefail
          export PATH=${
            lib.makeBinPath [
              pkgs.coreutils
              pkgs.util-linux
            ]
          }
          ${installFirmware}
          mountpoint -q /boot/firmware || mount /boot/firmware
          install_firmware /boot/firmware "$1"
        '';
      };
    };
    tmp = {
      useTmpfs = true;
      tmpfsSize = "64M";
    };
  };
  zramSwap = {
    enable = true;
    memoryPercent = 25;
  };
  swapDevices = [ ];

  systemd = {
    tmpfiles.rules = [
      "f /var/lib/wave-os/ssh/kosciak 0644 root root - -"
    ];
    services.sendspin = {
      description = "Music Assistant receiver";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "sound.target"
      ];
      environment = {
        HOME = "/var/lib/sendspin";
        LD_LIBRARY_PATH = lib.makeLibraryPath [ pkgs.alsa-lib ];
      };
      serviceConfig = {
        ExecStart = lib.escapeShellArgs [
          (lib.getExe pkgs.sendspin-player)
          "--daemon"
          "--name"
          "zac"
          "--client-id"
          "zac"
          "--max-sample-rate"
          "48000"
          "--max-bit-depth"
          "16"
          "--preferred-codec"
          "pcm"
          # miniaudio marks no default device, so without this it plays into its null device.
          "--audio-device"
          "Bose Revolve SoundLink"
        ];
        DynamicUser = true;
        SupplementaryGroups = [ "audio" ];
        StateDirectory = "sendspin";
        Restart = "on-failure";
        RestartSec = "10s";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
      };
    };
    coredump.settings.Coredump = {
      Storage = "none";
      ProcessSizeMax = 0;
    };
  };

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    extra-substituters = [ "https://wave-os.cachix.org" ];
    extra-trusted-public-keys = [ "wave-os.cachix.org-1:cwQ73uY7ZSe7Rqb8jWzu2/fYWXfe0An7DjsSPXNVgRw=" ];
    max-jobs = 0;
    keep-outputs = false;
    keep-derivations = false;
  };
  documentation = {
    enable = false;
    nixos.enable = false;
  };
  sdImage = {
    # Room for two kernel and initrd sets while a generation switches.
    firmwareSize = 256;
    populateFirmwareCommands = ''
      cp ${pkgs.raspberrypifw}/share/raspberrypi/boot/{bootcode.bin,fixup.dat,start.elf} firmware/
      ${installFirmware}
      install_firmware firmware ${config.system.build.toplevel}
    '';
    populateRootCommands = "";
  };
  system.stateVersion = "26.05";
}
