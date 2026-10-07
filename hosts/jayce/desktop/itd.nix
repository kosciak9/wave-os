{ lib, pkgs, ... }:

let
  sessionTarget = "wayland-session@hyprland.desktop.target";
  itd = pkgs.itd.overrideAttrs (old: {
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
in
{
  home.packages = [
    itd
    (lib.hiPrio itctl)
  ];

  xdg.configFile."itd/itd.toml".source = (pkgs.formats.toml { }).generate "itd.toml" {
    conn.reconnect = true;
    on = {
      connect.notify = true;
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

  systemd.user.services.quickshell.Service.Environment = [ "WAVE_ITCTL=${lib.getExe itctl}" ];

  programs.herdr.extraPlugins.watch-notify = pkgs.callPackage ./herdr-watch.nix { inherit itctl; };
}
