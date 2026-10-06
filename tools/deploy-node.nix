{
  pkgs,
  deployLib,
  configuration,
  hostname,
}:
let
  inherit (configuration) config;
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  switch =
    if isDarwin then
      # sudo on darwin keeps the caller's HOME, which darwin activation relies on.
      "HOME=/var/root $PROFILE/activate"
    else
      ''
        # work around https://github.com/NixOS/nixpkgs/issues/73404
        cd /tmp
        $PROFILE/bin/switch-to-configuration switch
        ${pkgs.lib.optionalString config.boot.loader.systemd-boot.enable
          # https://github.com/serokell/deploy-rs/issues/31
          "sed -i '/^default /d' ${config.boot.loader.efi.efiSysMountPoint}/loader/loader.conf"
        }
      '';
  # A failed health window fails activation, so deploy-rs restores the previous generation.
  profile = deployLib.activate.custom config.system.build.toplevel ''
    ${switch}
    ${pkgs.wave}/bin/wave health --wait --manifest ${config.wave.health.manifest}
  '';
in
assert config.wave.deployTarget.enable;
{
  inherit hostname;
  sshUser = "deploy";
  user = "root";
  sshOpts = [
    "-o"
    "BatchMode=yes"
    "-o"
    "ConnectTimeout=10"
  ];
  remoteBuild = true;
  autoRollback = true;
  magicRollback = true;
  activationTimeout = 600;
  confirmTimeout = 60;
  profiles.system = {
    path = profile;
    profilePath = "/nix/var/nix/profiles/system";
  };
}
