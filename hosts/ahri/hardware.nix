{ lib, ... }:

{
  boot = {
    loader = {
      grub.enable = false;
      generic-extlinux-compatible = {
        enable = true;
        configurationLimit = 5;
        useGenerationDeviceTree = true;
      };
    };
    kernelParams = [ "console=tty0" ];
    supportedFilesystems.zfs = lib.mkForce false;
  };

  hardware = {
    enableAllHardware = true;
    enableRedistributableFirmware = lib.mkForce false;
    raspberry-pi.firmware = {
      enable = true;
      uboot.enable = true;
    };
  };

  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/WAVE_ROOT";
      fsType = "ext4";
      options = [ "noatime" ];
    };
    "/boot/firmware" = {
      device = "/dev/disk/by-label/WAVE_BOOT";
      fsType = "vfat";
      options = lib.mkForce [ "noatime" ];
    };
  };
}
