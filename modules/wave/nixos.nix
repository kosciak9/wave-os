{
  config,
  lib,
  pkgs,
  ...
}:
let
  ip = lib.getExe' pkgs.iproute2 "ip";
in
{
  imports = [ ./common.nix ];

  config = lib.mkMerge [
    {
      wave = {
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
  ];
}
