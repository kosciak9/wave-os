{ lib, pkgs, ... }:

let
  sessionTarget = "wayland-session@hyprland.desktop.target";
  daemon = pkgs.writeShellApplication {
    name = "wave-voxtype-daemon";
    runtimeInputs = with pkgs; [
      tailscale
      jq
      coreutils
      which
      wl-clipboard
      ydotool
      libnotify
    ];
    text = ''
      if ! dns_name=$(tailscale status --json 2>/dev/null | jq -er '
        [.Peer[] | select(.HostName == "renekton") | .DNSName] |
        select(length == 1) | .[0] | rtrimstr(".") |
        select(test("^[a-zA-Z0-9-]+\\.[a-zA-Z0-9.-]+\\.ts\\.net$"))
      '); then
        printf '%s\n' "voxtype: transcription peer unavailable in Tailscale" >&2
        exit 1
      fi
      export YDOTOOL_SOCKET=/run/ydotoold/socket
      exec ${lib.getExe pkgs.voxtype} --quiet --remote-endpoint "https://$dns_name:8443" daemon
    '';
  };
in
{
  home.packages = [ pkgs.voxtype ];

  programs.ghostty.settings.keybind = [ "shift+insert=paste_from_clipboard" ];

  xdg.configFile."voxtype/config.toml".source =
    (pkgs.formats.toml { }).generate "voxtype-config.toml"
      {
        engine = "whisper";
        state_file = "auto";
        hotkey.enabled = false;
        osd.enabled = false;
        audio = {
          device = "default";
          sample_rate = 16000;
          max_duration_secs = 60;
        };
        whisper = {
          mode = "remote";
          # The daemon supplies the private tailnet DNS name; direct starts fail closed.
          remote_endpoint = "http://127.0.0.1:18080";
          remote_timeout_secs = 180;
          language = "pl";
          translate = false;
        };
        output = {
          mode = "clipboard";
          paste_keys = "shift+insert";
          pre_type_delay_ms = 200;
          auto_submit = false;
          wait_for_modifier_release = false;
          notification = {
            on_recording_start = true;
            on_recording_stop = true;
            on_transcription = true;
          };
        };
        text.filter_filler_words = false;
      };

  systemd.user.services.voxtype = {
    Unit = {
      Description = "Dictation via the shared remote Whisper backend";
      After = [ "wayland-session-waitenv.service" ];
      PartOf = [ sessionTarget ];
      ConditionEnvironment = "WAYLAND_DISPLAY";
    };
    Service = {
      ExecStart = lib.getExe daemon;
      Restart = "on-failure";
      RestartSec = 10;
      UMask = "0077";
    };
    Install.WantedBy = [ sessionTarget ];
  };
}
