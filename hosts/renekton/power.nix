{ config, lib, ... }:

let
  powerPrimaryUser = config.system.primaryUser;
  powerPrimaryUserArg = lib.escapeShellArg powerPrimaryUser;
in
{
  power = {
    restartAfterPowerFailure = true;

    sleep = {
      computer = "never";
      display = 5;
    };
  };

  system.defaults.screensaver = {
    askForPassword = true;
    askForPasswordDelay = 0;
  };

  system.activationScripts.power.text = lib.mkAfter ''
    # Disable explicit as well as idle system sleep; display sleep remains enabled.
    /usr/bin/pmset -a disablesleep 1

    # Activation runs as root. Enter the primary user's GUI launchd context
    # and then run defaults as that user, preserving unrelated preference keys.
    power_primary_user_uid=$(/usr/bin/id -u ${powerPrimaryUserArg})
    if /bin/launchctl print "gui/$power_primary_user_uid" >/dev/null 2>&1; then
      run_as_power_primary_user() {
        /bin/launchctl asuser "$power_primary_user_uid" /usr/bin/sudo --user ${powerPrimaryUserArg} -- "$@"
      }

      run_as_power_primary_user /usr/bin/defaults -currentHost write com.apple.screensaver idleTime -int 180
    else
      printf '%s\n' 'warning: the primary user GUI launchd domain is unavailable; persisting screensaver idleTime directly; the timer may require a logout/login before the GUI observes the change' >&2
      /usr/bin/sudo --user ${powerPrimaryUserArg} -- /usr/bin/defaults -currentHost write com.apple.screensaver idleTime -int 180
    fi
  '';
}
