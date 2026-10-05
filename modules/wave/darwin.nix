{ ... }:
{
  imports = [ ./common.nix ];

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
      wave_directory /private/var/lib/wave-os/state/native 0755 root wheel
      wave_directory /private/var/lib/wave-os/secrets 0700 root wheel
    ) || exit 1
  '';
}
