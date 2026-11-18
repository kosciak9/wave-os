{ lib, pkgs, ... }:

let
  sessionTarget = "wayland-session@hyprland.desktop.target";
  maxDurationSecs = 300;
  audioLevels = pkgs.writeScriptBin "wave-voxtype-levels" (
    "#!${lib.getExe pkgs.python3}\n" + builtins.readFile ./voxtype-levels.py
  );
  daemon = pkgs.writeShellApplication {
    name = "wave-voxtype-daemon";
    runtimeInputs = with pkgs; [
      which
      wl-clipboard
      ydotool
      libnotify
    ];
    text = ''
      export YDOTOOL_SOCKET=/run/ydotoold/socket
      exec ${lib.getExe pkgs.voxtype} --quiet daemon
    '';
  };
in
{
  home.packages = [
    pkgs.voxtype
    audioLevels
  ];

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
          max_duration_secs = maxDurationSecs;
        };
        whisper = {
          mode = "remote";
          remote_endpoint = "https://zilean.wave.exposed:8443";
          remote_timeout_secs = 180;
          language = "pl";
          translate = false;
        };
        output = {
          mode = "paste";
          paste_keys = "shift+insert";
          post_process.command = ''
            text="$(${lib.getExe' pkgs.coreutils "cat"})"
            case "$text" in
              *[![:space:]]*) printf '[transkrypcja] %s' "$text" ;;
            esac
          '';
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

  systemd.user.services = {
    voxtype = {
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

    quickshell.Service.Environment = [
      "WAVE_DICTATION_MAX_DURATION_MS=${toString (maxDurationSecs * 1000)}"
    ];
  };
}
