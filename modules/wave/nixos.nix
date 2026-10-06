{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.wave;
  ip = lib.getExe' pkgs.iproute2 "ip";
in
{
  imports = [ ./common.nix ];

  config = lib.mkMerge [
    {
      wave = {
        deployTarget.authorizedKeysDirectory = "/var/lib/wave-os/ssh";
        health.checks = {
          network = ''
            [[ -n "$(${ip} -4 route show default)" || -n "$(${ip} -6 route show default)" ]]
          '';
          dns = ''
            ${lib.getExe' pkgs.getent "getent"} ahosts example.com >/dev/null
          '';
        };
      };

      systemd.tmpfiles.rules = [
        "d /var/lib/wave-os 0755 root root - -"
        "d /var/lib/wave-os/source 0700 kosciak ${config.users.users.kosciak.group} - -"
        "d /var/lib/wave-os/state 0755 root root - -"
        "d /var/lib/wave-os/state/cli 0700 kosciak ${config.users.users.kosciak.group} - -"
      ];
    }

    (lib.mkIf cfg.deployTarget.enable {
      users = {
        groups.deploy = { };
        users.deploy = {
          isSystemUser = true;
          group = "deploy";
          description = "Wave deployment";
          shell = pkgs.bashInteractive;
        };
      };
      security.sudo.extraRules = [
        {
          users = [ "deploy" ];
          commands = [
            {
              command = "ALL";
              options = [ "NOPASSWD" ];
            }
          ];
        }
      ];
      nix.settings.trusted-users = [ "deploy" ];
      services.openssh.authorizedKeysFiles = [ "${cfg.deployTarget.authorizedKeysDirectory}/%u" ];
      systemd.tmpfiles.rules = [
        "d ${cfg.deployTarget.authorizedKeysDirectory} 0755 root root - -"
        "f ${cfg.deployTarget.authorizedKeysDirectory}/deploy 0644 root root - -"
      ];
    })
  ];
}
