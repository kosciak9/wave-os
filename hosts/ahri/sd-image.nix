{
  config,
  pkgs,
  sshPublicKey,
  ...
}:

let
  authorizedKey = pkgs.writeText "ahri-authorized-key" (sshPublicKey + "\n");
in
{
  assertions = [
    {
      assertion = builtins.match "ssh-ed25519 [A-Za-z0-9+/=]+" sshPublicKey != null;
      message = "Pass one Ed25519 public key without its comment to lib.mkAhriImage; never pass a private key.";
    }
  ];

  image.baseName = "wave-ahri";
  sdImage = {
    firmwarePartitionName = "WAVE_BOOT";
    rootVolumeLabel = "WAVE_ROOT";
    firmwareSize = 128;
    compressImage = false;
    populateRootCommands = ''
      mkdir -p ./files/boot
      ${config.boot.loader.generic-extlinux-compatible.populateCmd} -c ${config.system.build.toplevel} -d ./files/boot
      install -d -m 0700 ./files/var/lib/wave/ssh
      install -m 0600 ${authorizedKey} ./files/var/lib/wave/ssh/kosciak
    '';
  };
}
