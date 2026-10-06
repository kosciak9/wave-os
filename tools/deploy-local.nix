{
  pkgs,
  deployLib,
  configuration,
  host,
  interactiveSudo ? true,
}:
let
  owner = "kosciak";
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  systemClosure = configuration.config.system.build.toplevel;
  deployProfile =
    if isDarwin then
      deployLib.activate.darwin configuration
    else
      deployLib.activate.nixos configuration;
  nativeProfile = pkgs.symlinkJoin {
    name = "wave-${host}-native-profile";
    paths = [ deployProfile ];
    postBuild = ''
      rm -f "$out/systemConfig"
      printf '%s' '${systemClosure}' > "$out/systemConfig"
    '';
  };
  sudo = if isDarwin then "/usr/bin/sudo" else "/run/wrappers/bin/sudo";
  context = "--host ${host} --profile ${nativeProfile} --system ${systemClosure} --owner ${owner}";

  rootStdio = pkgs.writeShellScript "wave-deploy-root-inner" ''
    set -euo pipefail
    exec ${pkgs.wave}/bin/wave __native ${context} -- "$@"
  '';

  sudoWrapper = pkgs.writeShellScript "wave-deploy-root" ''
    set -euo pipefail
    if (( $# < 1 )) || [[ $1 != root ]]; then
      printf '%s\n' 'wave-deploy-root: first argument must be root' >&2
      exit 2
    fi
    shift
    if (( $# > 0 )) && [[ $1 == rm ]]; then
      if (( $# != 2 )); then
        printf '%s\n' 'wave-deploy-root: invalid confirmation argument count' >&2
        exit 2
      fi
      exec ${pkgs.wave}/bin/wave __confirm ${context} --root-wrapper ${rootStdio} -- "$2"
    fi
    exec ${sudo} ${if interactiveSudo then ''-S -p ""'' else "-n"} -u root ${rootStdio} "$@"
  '';

  node = {
    hostname = "localhost";
    sshUser = owner;
    user = "root";
    sshOpts = [
      "-o"
      "BatchMode=yes"
      "-o"
      "StrictHostKeyChecking=yes"
      "-o"
      "ConnectionAttempts=1"
      "-o"
      "ConnectTimeout=5"
    ];
    autoRollback = true;
    magicRollback = true;
    inherit interactiveSudo;
    fastConnection = true;
    confirmTimeout = 150;
    activationTimeout = 300;
    tempPath = if isDarwin then "/private/tmp" else "/tmp";
    sudo = toString sudoWrapper;
    profiles.system = {
      user = "root";
      path = nativeProfile;
      profilePath = "/nix/var/nix/profiles/system";
    };
  };
in
{
  inherit node sudoWrapper rootStdio;
}
