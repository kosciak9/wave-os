{ config, pkgs, ... }:

let
  checkIntervalSeconds = 60;
  wifiCycleAfterSeconds = 3 * 60;
  authRestartAfterWifiCycleSeconds = 15 * 60;
  minSecondsBetweenAuthRestarts = 6 * 60 * 60;
  lastAuthRestartFile = "/var/db/wave-network-guard/last-authrestart";
  recoveryKeyFile = config.sops.secrets."filevault/recovery-key".path;

  # Restores renekton's Wi-Fi-only uplink when the local network is lost: first by cycling
  # Wi-Fi power, then by a rate-limited FileVault authenticated restart, which comes back to
  # the login window with system services up. A plain reboot would stop at the FileVault
  # unlock screen, so without a working recovery key the guard only keeps cycling Wi-Fi.
  # It checks the LAN only (default route and gateway), so an outage beyond the router
  # never triggers recovery.
  networkGuard = pkgs.writeShellScript "wave-network-guard" ''
    set -u

    log() {
      /usr/bin/printf '%s %s\n' "$(/bin/date '+%Y-%m-%dT%H:%M:%S%z')" "$*"
    }

    lan_reachable() {
      local gateway
      gateway=$(/sbin/route -n get default 2>/dev/null | /usr/bin/awk '$1 == "gateway:" { print $2; exit }')
      /bin/test -n "$gateway" && /sbin/ping -c 3 -t 5 -o "$gateway" >/dev/null 2>&1
    }

    wifi_device() {
      /usr/sbin/networksetup -listallhardwareports \
        | /usr/bin/awk '/^Hardware Port: Wi-Fi$/ { getline; print $2; exit }'
    }

    cycle_wifi() {
      local device
      device=$(wifi_device)
      if ! /bin/test -n "$device"; then
        log "no Wi-Fi device found; cannot cycle Wi-Fi"
        return
      fi
      log "LAN unreachable; cycling Wi-Fi power on $device"
      /usr/sbin/networksetup -setairportpower "$device" off
      /bin/sleep 5
      /usr/sbin/networksetup -setairportpower "$device" on
    }

    # fdesetup reads the key from stdin, so it never lands in a file or an argument list.
    recovery_key_plist() {
      local key
      key=$(/bin/cat ${recoveryKeyFile}) || return 1
      /usr/bin/printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>Password</key><string>%s</string></dict></plist>\n' "$key"
    }

    auth_restart_allowed() {
      local last_auth_restart
      last_auth_restart=$(/bin/cat ${lastAuthRestartFile} 2>/dev/null || echo 0)
      /bin/test $(( $(/bin/date +%s) - last_auth_restart )) -ge ${toString minSecondsBetweenAuthRestarts}
    }

    # Returns only on failure; a plain restart is never a fallback.
    auth_restart() {
      if ! recovery_key_plist | /usr/bin/fdesetup validaterecovery -inputplist | /usr/bin/grep -qx true; then
        log "FileVault recovery key unavailable or invalid; not restarting"
        return
      fi
      log "LAN still unreachable after cycling Wi-Fi; FileVault authenticated restart"
      /bin/mkdir -p "$(/usr/bin/dirname ${lastAuthRestartFile})"
      /bin/date +%s > ${lastAuthRestartFile}
      if recovery_key_plist | /usr/bin/fdesetup authrestart -inputplist; then
        /bin/sleep 600
      fi
      log "FileVault authenticated restart failed"
    }

    unreachable_since=""
    wifi_cycled_at=""

    while :; do
      now=$(/bin/date +%s)
      if lan_reachable; then
        if /bin/test -n "$unreachable_since"; then
          log "LAN reachable again after $(( now - unreachable_since ))s"
        fi
        unreachable_since=""
        wifi_cycled_at=""
      elif ! /bin/test -n "$unreachable_since"; then
        log "LAN unreachable"
        unreachable_since=$now
      elif ! /bin/test -n "$wifi_cycled_at"; then
        if /bin/test $(( now - unreachable_since )) -ge ${toString wifiCycleAfterSeconds}; then
          cycle_wifi
          wifi_cycled_at=$(/bin/date +%s)
        fi
      elif /bin/test $(( now - wifi_cycled_at )) -ge ${toString authRestartAfterWifiCycleSeconds}; then
        if auth_restart_allowed; then
          auth_restart
        fi
        cycle_wifi
        wifi_cycled_at=$(/bin/date +%s)
      fi
      /bin/sleep ${toString checkIntervalSeconds}
    done
  '';
in
{
  sops.secrets."filevault/recovery-key" = { };

  launchd.daemons.wave-network-guard.serviceConfig = {
    ProgramArguments = [ "${networkGuard}" ];
    RunAtLoad = true;
    KeepAlive = true;
    ThrottleInterval = 10;
    StandardErrorPath = "/var/log/wave-network-guard.log";
    StandardOutPath = "/var/log/wave-network-guard.log";
  };
}
