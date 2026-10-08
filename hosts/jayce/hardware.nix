{
  config,
  lib,
  modulesPath,
  ...
}:

{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot = {
    initrd = {
      # systemd records the active Btrfs swapfile location in EFI at hibernation,
      # then resolves it after unlocking LUKS in the initrd.
      systemd.enable = true;
      availableKernelModules = [
        "nvme"
        "xhci_pci"
        "thunderbolt"
        "usbhid"
        "usb_storage"
        "sd_mod"
      ];
      kernelModules = [ ];
    };
    kernelModules = [ "kvm-amd" ];
    extraModulePackages = [ ];
  };

  fileSystems = {
    "/" = {
      device = "/dev/mapper/luks-3c161819-f22b-41cc-bea2-5be6baeb39bf";
      fsType = "btrfs";
    };
    "/home" = {
      device = "/dev/mapper/luks-3c161819-f22b-41cc-bea2-5be6baeb39bf";
      fsType = "btrfs";
      options = [ "subvol=home" ];
    };
    "/nix" = {
      device = "/dev/mapper/luks-3c161819-f22b-41cc-bea2-5be6baeb39bf";
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

  boot.initrd.luks.devices."luks-3c161819-f22b-41cc-bea2-5be6baeb39bf".device =
    "/dev/disk/by-uuid/3c161819-f22b-41cc-bea2-5be6baeb39bf";

  swapDevices = [
    {
      device = "/swap/swapfile";
      size = 65536;
      priority = 0;
    }
  ];
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
