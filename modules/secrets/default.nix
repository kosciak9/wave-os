{ sopsModule, sopsSource }:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.wave-secrets;
  cacheFile = "${cfg.cacheDirectory}/bundle.enc.json";
  upstream = (import sopsSource { inherit pkgs; }).sops-install-secrets;
  installer = pkgs.callPackage ../../packages/wave-secrets.nix {
    inherit upstream cacheFile;
    inherit (cfg) sourceFile rcloneConfigFile;
  };
  refresh = pkgs.writeShellScriptBin "wave-secrets-refresh" ''
    ${lib.optionalString pkgs.stdenv.hostPlatform.isLinux "export SOPS_RESTART_UNITS_VIA_SYSTEMCTL=1"}
    exec ${installer}/bin/sops-install-secrets --refresh ${config.system.build.sops-nix-manifest}
  '';
in
{
  imports = [ sopsModule ];

  options.services.wave-secrets = {
    enable = lib.mkEnableOption "external ciphertext transport for sops-nix";
    sourceFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/wave-secrets/source";
      description = "Private runtime file containing one absolute local path or rclone remote object.";
    };
    cacheDirectory = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/wave-secrets/cache";
      description = "Private directory for the last verified ciphertext, outside Git and the Nix store.";
    };
    rcloneConfigFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Private runtime rclone configuration for S3/B2 or another remote; null for local sources.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.sops.secrets != { };
        message = "wave-secrets requires declarations under sops.secrets.";
      }
      {
        assertion = config.sops.age.keyFile != null && config.sops.gnupg.home == null;
        message = "wave-secrets requires a local age key file, not a GnuPG keyring.";
      }
      {
        assertion = lib.all (
          secret: secret.sopsFile == cacheFile && secret.format == "json" && !secret.neededForUsers
        ) (lib.attrValues config.sops.secrets);
        message = "wave-secrets supports one external JSON bundle, not early user/password secrets.";
      }
      {
        assertion = lib.all (path: lib.hasPrefix "/" path && !(lib.hasPrefix "/nix/store/" path)) (
          [
            cfg.sourceFile
            cfg.cacheDirectory
          ]
          ++ lib.optional (cfg.rcloneConfigFile != null) cfg.rcloneConfigFile
        );
        message = "wave-secrets runtime paths must be absolute strings outside the Nix store.";
      }
    ];

    sops = {
      defaultSopsFile = lib.mkForce cacheFile;
      defaultSopsFormat = lib.mkDefault "json";
      validateSopsFiles = lib.mkForce false;
      age.keyFile = lib.mkDefault "/var/lib/wave-secrets/host.age";
      age.sshKeyPaths = lib.mkForce [ ];
      gnupg.sshKeyPaths = lib.mkForce [ ];
      package = installer;
      validationPackage = upstream;
    };

    environment.systemPackages = [ refresh ];
    system.build.wave-secrets-refresh = refresh;
  };
}
