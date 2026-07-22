{
  config,
  lib,
  modulesPath,
  ...
}:

{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot = {
    initrd.availableKernelModules = [
      "nvme"
      "xhci_pci"
      "thunderbolt"
      "usbhid"
      "usb_storage"
      "sd_mod"
    ];
    initrd.kernelModules = [ ];
    kernelModules = [ "kvm-amd" ];
    extraModulePackages = [ ];
  };

  fileSystems = {
    "/" = {
      device = "/dev/mapper/luks-bc69f56b-c5a5-413e-b350-afd3ecd7aa1b";
      fsType = "btrfs";
    };
    "/home" = {
      device = "/dev/mapper/luks-bc69f56b-c5a5-413e-b350-afd3ecd7aa1b";
      fsType = "btrfs";
      options = [ "subvol=home" ];
    };
    "/nix" = {
      device = "/dev/mapper/luks-bc69f56b-c5a5-413e-b350-afd3ecd7aa1b";
      fsType = "btrfs";
      options = [ "subvol=nix" ];
    };
    "/boot" = {
      device = "/dev/disk/by-uuid/BAFB-52E8";
      fsType = "vfat";
      options = [
        "fmask=0077"
        "dmask=0077"
      ];
    };
  };

  boot.initrd.luks.devices."luks-bc69f56b-c5a5-413e-b350-afd3ecd7aa1b".device =
    "/dev/disk/by-uuid/bc69f56b-c5a5-413e-b350-afd3ecd7aa1b";

  swapDevices = [ ];
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
