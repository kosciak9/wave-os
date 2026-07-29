{ config, lib, ... }:

let
  primaryUser = config.system.primaryUser;
  primaryUserArg = lib.escapeShellArg primaryUser;
in
{
  system.activationScripts.postActivation.text = lib.mkAfter ''
    # Disable Spotlight indexing for the startup volume. These commands are
    # intentionally fatal: this is the supported volume policy for Renekton.
    /usr/bin/mdutil -i off /
    /usr/bin/mdutil -d /

    # Other mounted stores can be unsupported, transient, or managed by Time
    # Machine. Do not let those stores prevent activation.
    if ! /usr/bin/mdutil -a -i off; then
      printf '%s\n' 'warning: could not disable Spotlight indexing on every mounted store' >&2
    fi
    if ! /usr/bin/mdutil -a -d; then
      printf '%s\n' 'warning: could not disable Spotlight activity on every mounted store' >&2
    fi
    if ! /usr/bin/mdutil -a -s; then
      printf '%s\n' 'warning: could not print final Spotlight status' >&2
    fi

    # Activation runs as root. Enter the primary user's GUI launchd context
    # and then run defaults as that user, preserving unrelated preference keys.
    primary_user_uid=$(/usr/bin/id -u ${primaryUserArg})
    if /bin/launchctl print "gui/$primary_user_uid" >/dev/null 2>&1; then
      run_as_primary_user() {
        /bin/launchctl asuser "$primary_user_uid" /usr/bin/sudo --user ${primaryUserArg} -- "$@"
      }

      run_as_primary_user /usr/bin/defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys \
        -dict-add 64 '<dict><key>enabled</key><false/></dict>'
      run_as_primary_user /usr/bin/defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys \
        -dict-add 65 '<dict><key>enabled</key><false/></dict>'

      # Private API required to refresh Tahoe's active symbolic-hotkey settings.
      activate_settings=/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings
      if [ -x "$activate_settings" ]; then
        if ! run_as_primary_user "$activate_settings" -u; then
          printf '%s\n' 'warning: Spotlight hotkeys were persisted, but logout/login is required to refresh them' >&2
        fi
      else
        printf '%s\n' 'warning: activateSettings is unavailable; Spotlight hotkeys were persisted, but logout/login is required to refresh them' >&2
      fi
    else
      printf '%s\n' 'warning: Spotlight shortcut updates deferred until a Darwin activation occurs with the primary user GUI session available' >&2
    fi
  '';
}
