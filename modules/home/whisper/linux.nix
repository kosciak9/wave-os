{
  config,
  lib,
  pkgs,
  ...
}:

let
  whisper = pkgs.whisper-cpp-vulkan;
  temporaryDirectory = "${config.xdg.cacheHome}/whisper";
  recordingDirectory = "${config.xdg.dataHome}/whisper/recordings";
  modelPath = "${pkgs.openclaw-whisper-model}/share/openclaw/models/ggml-large-v3-turbo-q5_0.bin";
  recordingPython = pkgs.python3.withPackages (ps: [ ps.aiohttp ]);
  recordingProxy = pkgs.writeScriptBin "whisper-recording-proxy" (
    "#!${lib.getExe recordingPython}\n" + builtins.readFile ./recording-proxy.py
  );
  service = description: execStart: {
    Unit.Description = description;
    Service = {
      ExecStart = lib.escapeShellArgs execStart;
      Restart = "always";
      RestartSec = 10;
      UMask = "0077";
    };
    Install.WantedBy = [ "default.target" ];
  };
in
{
  home.activation.whisperDirectories =
    lib.hm.dag.entryBetween [ "reloadSystemd" ] [ "writeBoundary" ]
      ''
        run install -d -m 0700 -- ${lib.escapeShellArg temporaryDirectory} ${lib.escapeShellArg recordingDirectory}
      '';

  systemd.user.services = {
    # On the GPU through Vulkan.
    whisper-server = lib.recursiveUpdate (service "whisper.cpp transcription server" [
      (lib.getExe' whisper "whisper-server")
      "--model"
      modelPath
      "--host"
      "127.0.0.1"
      "--port"
      "18081"
      "--inference-path"
      "/v1/audio/transcriptions"
      "--language"
      "auto"
      "--no-timestamps"
      "--convert"
      "--tmp-dir"
      temporaryDirectory
    ]) { Service.Environment = [ "PATH=${lib.makeBinPath [ pkgs.ffmpeg ]}" ]; };

    whisper-recording-proxy = service "whisper.cpp recording proxy" [
      (lib.getExe recordingProxy)
      "--archive-dir"
      recordingDirectory
      "--backend-model"
      modelPath
      "--backend-version"
      whisper.version
    ];

    # Publish only inference, not the server's model-loading or browser endpoints.
    whisper-serve = service "Tailnet endpoint for whisper transcription" [
      (lib.getExe pkgs.tailscale)
      "serve"
      "--https=8443"
      "--set-path=/v1/audio/transcriptions"
      "--yes"
      "http://127.0.0.1:18080/v1/audio/transcriptions"
    ];
  };
}
