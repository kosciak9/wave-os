{ lib, pkgs, ... }:

let
  sessionTarget = "wayland-session@hyprland.desktop.target";
  itd = pkgs.itd.overrideAttrs (old: {
    postConfigure = (old.postConfigure or "") + ''
      # Failed RPC sessions stay closed; retrying Accept spins indefinitely.
      chmod u+w vendor/go.elara.ws/drpc/muxserver{,/muxserver.go}
      patch -p1 < ${./itd-rpc-session.patch}
    '';
    postPatch = (old.postPatch or "") + ''
      # A disabled weather worker never drains this channel; reconnect must not block.
      substituteInPlace main.go --replace-fail 'sendWeatherCh <- struct{}{}' 'select {
          case sendWeatherCh <- struct{}{}:
          default:
          }'
      substituteInPlace notifs.go --replace-fail \
        '// Connect to dbus session bus' \
        'if !k.Bool("notifs.enabled") { return nil }
        // Connect to dbus session bus'
    '';
  });
  itctl = pkgs.writeShellScriptBin "itctl" ''
    exec ${itd}/bin/itctl --socket-path "''${XDG_RUNTIME_DIR:?}/itd/socket" "$@"
  '';
  healthCheck = pkgs.writeShellApplication {
    name = "itd-health-check";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.systemd
    ];
    text = ''
      cd "$XDG_RUNTIME_DIR/itd-health"
      read -r uptime _ < /proc/uptime
      now=''${uptime%%.*}
      pid=$(systemctl --user show itd.service --property=MainPID --value)
      previous_pid=0 last_check=0 failures=0 delay=120 retry_at=0
      if [[ -f state ]]; then
        read -r previous_pid last_check failures delay retry_at < state
      fi

      save_state() {
        printf '%s %s %s %s %s\n' "$pid" "$now" "$failures" "$delay" "$retry_at" > state
      }
      publish() {
        printf '%s\n' "$1" > battery.tmp
        mv battery.tmp battery
      }

      # A new process or a gap across suspend gets one interval to reconnect.
      if [[ "$pid" != "$previous_pid" ]] || (( now - last_check > 180 )); then
        failures=0
        publish -1
        save_state
        exit 0
      fi
      if [[ "$pid" == 0 ]] || [[ $(busctl --system get-property org.bluez /org/bluez/hci0 org.bluez.Adapter1 Powered) != 'b true' ]]; then
        failures=0
        publish -1
        save_state
        exit 0
      fi

      if battery=$(timeout --kill-after=2 10 ${lib.getExe itctl} get battery); then
        publish "''${battery%%%}"
        failures=0 delay=120 retry_at=0
      else
        publish -1
        failures=$((failures + 1))
        if (( failures >= 3 && now >= retry_at )); then
          echo "Battery read failed $failures times; restarting itd (retry interval: ''${delay}s)"
          systemctl --user try-restart itd.service
          failures=0
          retry_at=$((now + delay))
          case "$delay" in
            120) delay=300 ;;
            *) delay=900 ;;
          esac
        fi
      fi
      save_state
    '';
  };
in
{
  home.packages = [
    itd
    (lib.hiPrio itctl)
  ];

  xdg.configFile."itd/itd.toml".source = (pkgs.formats.toml { }).generate "itd.toml" {
    conn.reconnect = true;
    on = {
      connect.notify = false;
      reconnect = {
        notify = false;
        setTime = true;
      };
    };
    notifs = {
      # Only explicit itctl notifications should reach the watch.
      enabled = false;
      translit.use = [
        "eASCII"
        "Emoji"
      ];
      ignore = {
        sender = [ ];
        summary = [ "InfiniTime" ];
        body = [ ];
      };
    };
    weather.enabled = false;
    metrics.enabled = false;
    fuse.enabled = false;
    logging.level = "info";
  };

  systemd.user.services.itd = {
    Unit = {
      Description = "InfiniTime notification and Bluetooth companion";
      After = [ "wayland-session-waitenv.service" ];
      PartOf = [ sessionTarget ];
      StartLimitIntervalSec = 0;
    };
    Service = {
      ExecStart = "${itd}/bin/itd";
      Environment = [ "ITD_SOCKET_PATH=%t/itd/socket" ];
      RuntimeDirectory = "itd";
      RuntimeDirectoryMode = "0700";
      UMask = "0077";
      Restart = "always";
      RestartSec = 10;
      TimeoutStopSec = 10;
    };
    Install.WantedBy = [ sessionTarget ];
  };

  systemd.user.services.itd-health = {
    Unit = {
      Description = "Check InfiniTime communication and recover itd";
      After = [ "itd.service" ];
      PartOf = [ sessionTarget ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = lib.getExe healthCheck;
      TimeoutStartSec = 45;
      RuntimeDirectory = "itd-health";
      RuntimeDirectoryMode = "0700";
      RuntimeDirectoryPreserve = "yes";
      UMask = "0077";
    };
  };
  systemd.user.timers.itd-health = {
    Unit.PartOf = [ sessionTarget ];
    Timer = {
      OnActiveSec = "30s";
      OnUnitInactiveSec = "2min";
      AccuracySec = "5s";
    };
    Install.WantedBy = [ sessionTarget ];
  };

  programs.herdr.extraPlugins.watch-notify = pkgs.callPackage ./herdr-watch.nix { inherit itctl; };
}
