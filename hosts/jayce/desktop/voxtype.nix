{
  lib,
  pkgs,
  osConfig,
  ...
}:

let
  sessionTarget = "wayland-session@hyprland.desktop.target";
  maxDurationSecs = 300;
  audioLevels = pkgs.writeScriptBin "wave-voxtype-levels" (
    "#!${lib.getExe pkgs.python3}\n" + builtins.readFile ./voxtype-levels.py
  );
  proxyConfig = (pkgs.formats.yaml { }).generate "voxtype-proxy.yaml" {
    model_list = [
      {
        model_name = "dictation";
        litellm_params = {
          model = "openai/whisper-1";
          api_base = "os.environ/VOXTYPE_WHISPER_API_BASE";
          api_key = "local";
          order = 1;
          timeout = 60;
          max_retries = 0;
          response_format = "json";
        };
        model_info = {
          id = "renekton";
          mode = "audio_transcription";
          health_check_timeout = 10;
        };
      }
      {
        model_name = "dictation";
        litellm_params = {
          model = "openai/elevenlabs/scribe-v2";
          api_base = "https://openrouter.ai/api/v1";
          api_key = "os.environ/OPENROUTER_API_KEY";
          order = 2;
          timeout = 120;
          max_retries = 0;
          response_format = "json";
        };
        model_info = {
          id = "openrouter-scribe";
          mode = "audio_transcription";
          disable_background_health_check = true;
        };
      }
    ];
    router_settings = {
      num_retries = 0;
      allowed_fails = 0;
      cooldown_time = 180;
      max_fallbacks = 1;
    };
    general_settings = {
      background_health_checks = true;
      health_check_interval = 180;
      enable_health_check_routing = true;
      health_check_staleness_threshold = 360;
      health_check_skip_disabled_background_models = true;
      health_check_details = false;
      disable_spend_logs = true;
    };
    litellm_settings = {
      telemetry = false;
      turn_off_message_logging = true;
      redact_messages_in_exceptions = true;
    };
  };
  proxy = pkgs.writeShellApplication {
    name = "wave-voxtype-proxy";
    runtimeInputs = with pkgs; [
      tailscale
      jq
    ];
    text = ''
      if ! dns_name=$(tailscale status --json 2>/dev/null | jq -er '
        [.Peer[] | select(.HostName == "renekton") | .DNSName] |
        select(length == 1) | .[0] | rtrimstr(".") |
        select(test("^[a-zA-Z0-9-]+\\.[a-zA-Z0-9.-]+\\.ts\\.net$"))
      '); then
        printf '%s\n' "voxtype: transcription peer missing from Tailscale" >&2
        exit 1
      fi
      export VOXTYPE_WHISPER_API_BASE="https://$dns_name:8443/v1"
      OPENROUTER_API_KEY=$(< ${
        lib.escapeShellArg osConfig.sops.secrets."voxtype/openrouter-api-key".path
      })
      export OPENROUTER_API_KEY
      export LITELLM_LOCAL_MODEL_COST_MAP=True
      exec ${lib.getExe pkgs.litellm} --host 127.0.0.1 --port 18080 --config ${proxyConfig} --telemetry False
    '';
  };
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
    pkgs.litellm
    audioLevels
  ];

  programs.ghostty.settings.keybind = [ "shift+insert=paste_from_clipboard" ];
  programs.zsh.generatedCompletions.litellm = "${lib.getExe' pkgs.coreutils "env"} LITELLM_LOCAL_MODEL_COST_MAP=True _LITELLM_COMPLETE=zsh_source ${lib.getExe pkgs.litellm}";

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
          remote_endpoint = "http://127.0.0.1:18080";
          remote_model = "dictation";
          # Covers a failed Whisper request followed by an OpenRouter request.
          remote_timeout_secs = 210;
          language = "pl";
          translate = false;
        };
        output = {
          mode = "paste";
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

  systemd.user.services = {
    voxtype-proxy = {
      Unit = {
        Description = "Dictation routing to renekton with OpenRouter Scribe fallback";
        PartOf = [ sessionTarget ];
        Before = [ "voxtype.service" ];
      };
      Service = {
        ExecStart = lib.getExe proxy;
        Restart = "on-failure";
        RestartSec = 10;
        UMask = "0077";
      };
      Install.WantedBy = [ sessionTarget ];
    };

    voxtype = {
      Unit = {
        Description = "Dictation via Whisper with OpenRouter Scribe fallback";
        After = [
          "wayland-session-waitenv.service"
          "voxtype-proxy.service"
        ];
        Wants = [ "voxtype-proxy.service" ];
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
