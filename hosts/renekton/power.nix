{ config, lib, ... }:

let
  powerPrimaryUser = config.system.primaryUser;
  powerPrimaryUserArg = lib.escapeShellArg powerPrimaryUser;
  screensaverIdleSeconds = 180;
in
{
  system.defaults.screensaver = {
    askForPassword = true;
    askForPasswordDelay = 0;
  };

  # nix-darwin's power and sleep options rewrite Energy Saver prefs on every activation, and
  # renekton's network dropped right after such a rewrite; settings are written only on drift.
  system.activationScripts.power.text = lib.mkAfter ''
    pmset_current() {
      /usr/bin/pmset -g | /usr/bin/awk -v key="$1" '$1 == key { print $2; exit }'
    }

    ensure_pmset() {
      local reported_key="$1" setting="$2" value="$3"
      if [ "$(pmset_current "$reported_key")" != "$value" ]; then
        /usr/bin/pmset -a "$setting" "$value"
      fi
    }

    ensure_pmset autorestart autorestart 1
    ensure_pmset sleep sleep 0
    ensure_pmset displaysleep displaysleep 5
    # Disable explicit as well as idle system sleep; display sleep remains enabled.
    ensure_pmset SleepDisabled disablesleep 1

    # Activation runs as root. Enter the primary user's GUI launchd context
    # and then run defaults as that user, preserving unrelated preference keys.
    power_primary_user_uid=$(/usr/bin/id -u ${powerPrimaryUserArg})
    if /bin/launchctl print "gui/$power_primary_user_uid" >/dev/null 2>&1; then
      run_as_power_primary_user() {
        /bin/launchctl asuser "$power_primary_user_uid" /usr/bin/sudo --user ${powerPrimaryUserArg} -- "$@"
      }
    else
      printf '%s\n' 'warning: the primary user GUI launchd domain is unavailable; persisting screensaver idleTime directly; the timer may require a logout/login before the GUI observes the change' >&2
      run_as_power_primary_user() {
        /usr/bin/sudo --user ${powerPrimaryUserArg} -- "$@"
      }
    fi

    if [ "$(run_as_power_primary_user /usr/bin/defaults -currentHost read com.apple.screensaver idleTime 2>/dev/null)" != ${toString screensaverIdleSeconds} ]; then
      run_as_power_primary_user /usr/bin/defaults -currentHost write com.apple.screensaver idleTime -int ${toString screensaverIdleSeconds}
    fi
  '';
}
