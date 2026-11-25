{ modulesPath, ... }:

{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot = {
    bcache.enable = true;
    initrd.availableKernelModules = [
      "xhci_pci"
      "ehci_pci"
      "ahci"
      "nvme"
      "usb_storage"
      "sd_mod"
    ];
    kernelModules = [
      "kvm-intel"
      # NCT6792D Super I/O: motherboard fan and temperature control.
      "nct6775"
    ];
  };
  hardware.cpu.intel.updateMicrocode = true;

  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/ZILEAN_ROOT";
      fsType = "btrfs";
      options = [
        "subvol=root"
        "noatime"
        "compress=zstd"
      ];
    };
    "/home" = {
      device = "/dev/disk/by-label/ZILEAN_ROOT";
      fsType = "btrfs";
      options = [
        "subvol=home"
        "noatime"
        "compress=zstd"
      ];
      # Activation runs in initrd and reads the sops file from /home.
      neededForBoot = true;
    };
    "/home/kosciak/Developer" = {
      device = "/dev/disk/by-label/ZILEAN_SCRATCH";
      fsType = "btrfs";
      options = [
        "subvol=Developer"
        "noatime"
        "compress=zstd"
        "nofail"
        "x-systemd.device-timeout=30s"
      ];
    };
    # Rootless podman storage grows with every worktree's dev containers; keep it off the 120 GB root SSD.
    "/home/kosciak/.local/share/containers" = {
      device = "/dev/disk/by-label/ZILEAN_SCRATCH";
      fsType = "btrfs";
      options = [
        "subvol=containers"
        "noatime"
        "compress=zstd"
        "nofail"
        "x-systemd.device-timeout=30s"
      ];
    };
    # Regenerable caches (bun, chromium, nix, pnpm) grow by gigabytes a week.
    "/home/kosciak/.cache" = {
      device = "/dev/disk/by-label/ZILEAN_SCRATCH";
      fsType = "btrfs";
      options = [
        "subvol=cache"
        "noatime"
        "compress=zstd"
        "nofail"
        "x-systemd.device-timeout=30s"
      ];
    };
    "/home/kosciak/.npm" = {
      device = "/dev/disk/by-label/ZILEAN_SCRATCH";
      fsType = "btrfs";
      options = [
        "subvol=npm"
        "noatime"
        "compress=zstd"
        "nofail"
        "x-systemd.device-timeout=30s"
      ];
    };
    # Monitoring databases (DynamicUser state directories); default.nix makes the services require them.
    "/var/lib/private/victoriametrics" = {
      device = "/dev/disk/by-label/ZILEAN_STORAGE";
      fsType = "btrfs";
      options = [
        "subvol=victoriametrics"
        "noatime"
        "compress=zstd"
        "nofail"
        "x-systemd.device-timeout=30s"
      ];
    };
    "/var/lib/private/victorialogs" = {
      device = "/dev/disk/by-label/ZILEAN_STORAGE";
      fsType = "btrfs";
      options = [
        "subvol=victorialogs"
        "noatime"
        "compress=zstd"
        "nofail"
        "x-systemd.device-timeout=30s"
      ];
    };
    # Alfred's home holds his Podman storage and Proton Mail Bridge state (alfred.nix makes his
    # services require it).
    "/var/lib/alfred" = {
      device = "/dev/disk/by-label/ZILEAN_STORAGE";
      fsType = "btrfs";
      options = [
        "subvol=alfred"
        "noatime"
        "compress=zstd"
        "nofail"
        "x-systemd.device-timeout=30s"
      ];
    };
    "/nix" = {
      device = "/dev/disk/by-label/ZILEAN_ROOT";
      fsType = "btrfs";
      options = [
        "subvol=nix"
        "noatime"
        "compress=zstd"
      ];
    };
    "/boot" = {
      device = "/dev/disk/by-label/ZILEAN_EFI";
      fsType = "vfat";
      options = [ "umask=0077" ];
    };
    "/srv/storage" = {
      device = "/dev/disk/by-label/ZILEAN_STORAGE";
      fsType = "btrfs";
      options = [
        "subvol=storage"
        "noatime"
        "compress=zstd"
        "nofail"
        "x-systemd.device-timeout=30s"
      ];
    };
    "/srv/scratch" = {
      device = "/dev/disk/by-label/ZILEAN_SCRATCH";
      fsType = "btrfs";
      options = [
        "subvol=scratch"
        "noatime"
        "compress=zstd"
        "nofail"
        "x-systemd.device-timeout=30s"
      ];
    };
  };
}
