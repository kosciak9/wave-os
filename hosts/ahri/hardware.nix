{ lib, ... }:

{
  boot = {
    initrd = {
      systemd.enable = true;
      availableKernelModules = [
        "btrfs"
        "usb_storage"
        "uas"
        "xhci_pci"
        "sd_mod"
        "mmc_block"
        "sdhci_iproc"
      ];
    };
    loader = {
      grub.enable = false;
      generic-extlinux-compatible = {
        enable = true;
        configurationLimit = 5;
        useGenerationDeviceTree = true;
      };
    };
    kernelParams = [ "console=tty0" ];
    supportedFilesystems = [
      "btrfs"
      "ext4"
      "vfat"
    ];
  };

  hardware = {
    enableAllHardware = true;
    enableRedistributableFirmware = lib.mkForce false;
    deviceTree = {
      enable = true;
      filter = "bcm2711-rpi-*.dtb";
    };
  };

  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/WAVE_ROOT";
      fsType = "btrfs";
      options = [
        "subvol=@root"
        "noatime"
        "compress=zstd:1"
        "degraded"
      ];
    };
    # U-Boot reads kernel/initrd from SD, never from the multi-device root.
    "/boot" = {
      device = "/dev/disk/by-label/NIXOS_SD";
      fsType = "ext4";
      options = [ "noatime" ];
    };
    "/boot/firmware" = {
      device = "/dev/disk/by-label/FIRMWARE";
      fsType = "vfat";
      options = [
        "ro"
        "noatime"
      ];
    };
  };
}
