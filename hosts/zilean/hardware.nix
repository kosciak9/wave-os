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
