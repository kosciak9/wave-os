{ config, lib, ... }:
let
  cfg = config.wave;
in
{
  imports = [ ./common.nix ];

  config = lib.mkMerge [
    {
      wave = {
        deployTarget.authorizedKeysDirectory = "/private/var/lib/wave-os/ssh";
        health.checks = {
          network = ''
            /sbin/route -n get default >/dev/null 2>&1 || /sbin/route -n get -inet6 default >/dev/null 2>&1
          '';
          dns = ''
            /usr/bin/dscacheutil -q host -a name example.com | /usr/bin/grep -Eq '^ip(v6)?_address: '
          '';
        };
      };

      # Determinate Nix leaves nix-darwin's nix.gc unavailable, so prune generations directly.
      launchd.daemons.nix-gc.serviceConfig = {
        ProgramArguments = [
          "/nix/var/nix/profiles/default/bin/nix-collect-garbage"
          "--delete-older-than"
          "14d"
        ];
        StartCalendarInterval = [
          {
            Weekday = 1;
            Hour = 3;
            Minute = 15;
          }
        ];
      };

      system.activationScripts.postActivation.text = ''
        (
          set -eu
          # /var is Apple's alias; all provisioning below uses the physical path.
          for parent in /private /private/var; do
            if [ -L "$parent" ] || [ ! -d "$parent" ]; then
              printf 'wave: unsafe directory: %s\n' "$parent" >&2
              exit 1
            fi
          done
          wave_directory() {
            directory=$1
            mode=$2
            owner=$3
            group=$4
            if [ -L "$directory" ] || { [ -e "$directory" ] && [ ! -d "$directory" ]; }; then
              printf 'wave: unsafe directory: %s\n' "$directory" >&2
              exit 1
            fi
            /usr/bin/install -d -m "$mode" -o "$owner" -g "$group" "$directory"
          }
          owner_group=$(/usr/bin/id -gn kosciak)
          if [ -L /private/var/lib ] || { [ -e /private/var/lib ] && [ ! -d /private/var/lib ]; }; then
            printf '%s\n' 'wave: unsafe directory: /private/var/lib' >&2
            exit 1
          fi
          if [ ! -d /private/var/lib ]; then
            /usr/bin/install -d -m 0755 -o root -g wheel /private/var/lib
          fi
          wave_directory /private/var/lib/wave-os 0755 root wheel
          wave_directory /private/var/lib/wave-os/source 0700 kosciak "$owner_group"
          wave_directory /private/var/lib/wave-os/state 0755 root wheel
          wave_directory /private/var/lib/wave-os/state/cli 0700 kosciak "$owner_group"
          ${lib.optionalString cfg.deployTarget.enable ''
            wave_directory ${cfg.deployTarget.authorizedKeysDirectory} 0755 root wheel
            keys=${cfg.deployTarget.authorizedKeysDirectory}/deploy
            if [ -L "$keys" ]; then
              printf 'wave: unsafe file: %s\n' "$keys" >&2
              exit 1
            fi
            if [ ! -e "$keys" ]; then
              /usr/bin/install -m 0644 -o root -g wheel /dev/null "$keys"
            fi
            # Remote Login limited to selected users admits only this group's members.
            if /usr/bin/dscl . -read /Groups/com.apple.access_ssh >/dev/null 2>&1; then
              /usr/sbin/dseditgroup -o edit -a deploy -t user com.apple.access_ssh
            fi
          ''}
        ) || exit 1
      '';
    }

    (lib.mkIf cfg.deployTarget.enable {
      users = {
        knownUsers = [ "deploy" ];
        users.deploy = {
          uid = 455;
          gid = 20;
          description = "Wave deployment";
          home = "/var/empty";
          createHome = false;
          # zsh sources nix-darwin's /etc/zshenv, so non-interactive SSH commands find nix.
          shell = "/bin/zsh";
          isHidden = true;
        };
      };
      security.sudo.extraConfig = ''
        deploy ALL=(ALL) NOPASSWD: ALL
      '';
      determinateNix.customSettings.extra-trusted-users = [ "deploy" ];
      services.openssh.extraConfig = ''
        AuthorizedKeysFile .ssh/authorized_keys ${cfg.deployTarget.authorizedKeysDirectory}/%u
      '';
    })
  ];
}
