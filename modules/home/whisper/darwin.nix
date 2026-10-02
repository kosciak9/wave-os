{
  config,
  lib,
  pkgs,
  ...
}:

let
  logDirectory = "${config.home.homeDirectory}/Library/Logs/Whisper";
  temporaryDirectory = "${config.home.homeDirectory}/Library/Caches/Whisper";
in
{
  home.activation.whisperDirectories = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    ${lib.getExe' pkgs.coreutils "install"} -d -m 0700 -- "${logDirectory}" "${temporaryDirectory}"
  '';

  launchd.agents.whisper-server = {
    enable = true;
    domain = "gui";
    config = {
      ProgramArguments = [
        (lib.getExe' pkgs.whisper-cpp "whisper-server")
        "--model"
        "${pkgs.openclaw-whisper-model}/share/openclaw/models/ggml-large-v3-turbo-q5_0.bin"
        "--host"
        "127.0.0.1"
        "--port"
        "18080"
        "--inference-path"
        "/v1/audio/transcriptions"
        "--language"
        "auto"
        "--no-timestamps"
        "--convert"
        "--tmp-dir"
        temporaryDirectory
      ];
      EnvironmentVariables.PATH = "${lib.makeBinPath [ pkgs.ffmpeg ]}:/usr/bin:/bin";
      RunAtLoad = true;
      KeepAlive = true;
      ThrottleInterval = 10;
      ProcessType = "Background";
      Umask = 63;
      StandardOutPath = "${logDirectory}/server.log";
      StandardErrorPath = "${logDirectory}/server.error.log";
    };
  };

  # Publish only inference, not the server's model-loading or browser endpoints.
  launchd.agents.whisper-serve = {
    enable = true;
    domain = "gui";
    config = {
      ProgramArguments = [
        (lib.getExe pkgs.tailscale)
        "serve"
        "--https=8443"
        "--set-path=/v1/audio/transcriptions"
        "--yes"
        "http://127.0.0.1:18080/v1/audio/transcriptions"
      ];
      RunAtLoad = true;
      KeepAlive = true;
      ThrottleInterval = 10;
      ProcessType = "Background";
      Umask = 63;
      StandardOutPath = "/dev/null";
      StandardErrorPath = "${logDirectory}/serve.error.log";
    };
  };
}
