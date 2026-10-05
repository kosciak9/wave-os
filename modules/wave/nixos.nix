{ config, ... }:
{
  imports = [ ./common.nix ];

  systemd.tmpfiles.rules = [
    "d /var/lib/wave-os 0755 root root - -"
    "d /var/lib/wave-os/source 0700 kosciak ${config.users.users.kosciak.group} - -"
    "d /var/lib/wave-os/state 0755 root root - -"
    "d /var/lib/wave-os/state/cli 0700 kosciak ${config.users.users.kosciak.group} - -"
    "d /var/lib/wave-os/state/native 0755 root root - -"
    "d /var/lib/wave-os/secrets 0700 root root - -"
  ];
}
