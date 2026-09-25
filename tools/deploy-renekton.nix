{
  pkgs,
  deployLib,
  configuration,
}:
let
  confirmTimeout = 150;
  activationTimeout = 300;
  primaryUser = configuration.config.system.primaryUser;
  home = configuration.config.users.users.${primaryUser}.home;
  logPrefix = "${home}/.local/state/wave/logs/safe-switch/";
  nativeWrapper = deployLib.activate.darwin configuration;
  nativeExe = "${nativeWrapper}/activate-rs";
  helperPackage = pkgs.runCommand "wave-deploy-helpers" { } ''
    mkdir -p "$out"
    cp "${./wave_confirm.py}" "$out/wave_confirm.py"
    cp "${./wave_health.py}" "$out/wave_health.py"
    cp "${./wave_common.py}" "$out/wave_common.py"
  '';
  canaryName = "deploy-rs-canary-${
    builtins.substring 0 32 (builtins.baseNameOf (toString nativeWrapper))
  }";

  sudoWrapper = pkgs.writeShellScript "wave-deploy-root" ''
    set -euo pipefail
    if (( $# < 1 )) || [[ $1 != root ]]; then
      printf '%s\n' 'wave-deploy-root: first argument must be root' >&2
      exit 2
    fi
    shift
    if (( $# > 0 )) && [[ $1 == rm ]]; then
      if (( $# != 2 )) || [[ $2 != /private/tmp/wave-*/canary/deploy-rs-canary-* ]]; then
        printf '%s\n' 'wave-deploy-root: invalid rm request' >&2
        exit 2
      fi
      exec "${pkgs.python3}/bin/python3" "${helperPackage}/wave_confirm.py" "$2" "${nativeWrapper}" "${configuration.system}" "${rootStdio}" "${logPrefix}"
    fi
    exec /usr/bin/sudo -S -p "" -u root "${rootStdio}" "$@"
  '';

  rootStdio = pkgs.writeShellScript "wave-deploy-root-inner" ''
    set -euo pipefail
    set -C
    if (( EUID != 0 )); then
      printf '%s\n' 'wave-deploy-root-inner: must run as root' >&2
      exit 1
    fi
    export HOME=/var/root
    umask 022
    log=""

    fail() { printf 'wave-deploy-root-inner: %s\n' "$1" >&2; exit "''${2:-2}"; }
    validate_log() {
      candidate=$1
      case "$candidate" in
        /*) ;;
        *) fail 'log path is not absolute' ;;
      esac
      case "$candidate" in
        *[!A-Za-z0-9_./:-]*) fail 'log path contains unsafe characters' ;;
      esac
      [ -d "$candidate" ] || fail 'log directory does not exist'
      [ "$candidate" = "$(/usr/bin/readlink -f -- "$candidate")" ] || fail 'log path is not canonical'
      case "$candidate" in "${logPrefix}"*) ;; *) fail 'log path is outside the safe-switch directory' ;; esac
    }

    validate_temp() {
      temp=$1
      [ "$temp" = "$(/usr/bin/readlink -f -- "$temp")" ] || fail 'temp path is not canonical'
      case "$temp" in /private/tmp/wave-*/canary) ;; *) fail 'invalid temp path' ;; esac
      [ -d "$temp" ] || fail 'temp directory does not exist'
      [ -f "$temp/wave-log-dir" ] && [ ! -L "$temp/wave-log-dir" ] || fail 'invalid log mapping'
      [ -f "$temp/wave-old-profile" ] && [ ! -L "$temp/wave-old-profile" ] || fail 'invalid profile mapping'
      IFS= read -r mapped_log < "$temp/wave-log-dir" || fail 'cannot read log mapping'
      validate_log "$mapped_log"
      [ -z "$log" ] || [ "$mapped_log" = "$log" ] || fail 'log mapping mismatch'
    }

    if [ "$1" = rm ]; then
      [ "$#" -eq 2 ] || fail 'invalid confirmation argument count'
      canary=$2
      [ "$canary" = "$(/usr/bin/readlink -f -- "$canary")" ] || fail 'canary is not canonical'
      [ "$(/usr/bin/basename -- "$canary")" = "${canaryName}" ] || fail 'unexpected canary'
      temp=$(/usr/bin/dirname -- "$canary")
      validate_temp "$temp"
      log=$mapped_log
      [ ! -e "$log/cancelled" ] || exit 130
      exec /bin/rm -- "$canary"
    fi

    [ "$#" -ge 5 ] || fail 'incomplete native arguments'
    exe=$1
    [ "$2" = --log-dir ] || fail 'missing --log-dir'
    log=$3
    action=$4
    closure=$5
    [ "$exe" = "${nativeExe}" ] || fail 'unexpected native executable'
    validate_log "$log"
    [ "$closure" = "${nativeWrapper}" ] || fail 'activation closure mismatch'

    case "$action" in
      activate)
        [ "$#" -eq 13 ] || fail 'invalid activate argument count'
        [ "$6" = --profile-path ] && [ "$7" = /nix/var/nix/profiles/system ] || fail 'invalid profile path'
        [ "$8" = --temp-path ] || fail 'invalid temp argument'
        temp=$9
        [ "''${10}" = --confirm-timeout ] && [ "''${11}" = "${toString confirmTimeout}" ] || fail 'invalid confirmation timeout'
        [ "''${12}" = --magic-rollback ] && [ "''${13}" = --auto-rollback ] || fail 'invalid rollback flags'
        validate_temp "$temp"
        [ ! -L "$temp/wave-old-profile" ] || fail 'old profile mapping is a symlink'
        IFS= read -r old_profile < "$temp/wave-old-profile" || fail 'cannot read old profile'
        case "$old_profile" in /nix/store/*) ;; *) fail 'invalid old profile closure' ;; esac
        [ "$(/usr/bin/readlink -f -- /nix/var/nix/profiles/system)" = "$old_profile" ] || fail 'profile changed before activation'
        [ -x "$exe" ] || fail 'native executable is not executable'
        printf '%s\n' "$$" > "$log/native.pid"
        [ ! -e "$log/cancelled" ] || exit 130
         exec "$@" </dev/null >"$log/target-stdio.log" 2>&1
        ;;
      wait)
        [ "$#" -eq 9 ] || fail 'invalid wait argument count'
        [ "$6" = --temp-path ] || fail 'invalid temp argument'
        validate_temp "$7"
        [ "$8" = --activation-timeout ] && [ "$9" = "${toString activationTimeout}" ] || fail 'invalid activation timeout'
        exec "$@"
        ;;
      *) fail 'unsupported action' ;;
    esac
  '';

  node = {
    hostname = "localhost";
    sshUser = primaryUser;
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
    interactiveSudo = true;
    fastConnection = true;
    inherit confirmTimeout activationTimeout;
    tempPath = "/private/tmp";
    sudo = toString sudoWrapper;
    profiles.system = {
      user = "root";
      path = nativeWrapper;
      profilePath = "/nix/var/nix/profiles/system";
    };
  };
in
{
  inherit node sudoWrapper rootStdio;
}
