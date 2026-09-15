{
  config,
  lib,
  pkgs,
  ...
}:

let
  homeDirectory = config.home.homeDirectory;
  podman = lib.getExe pkgs.podman;
  jq = lib.getExe pkgs.jq;
  openclaw = lib.getExe config.programs.openclaw.package;
  common = import ./common.nix {
    inherit config lib pkgs;
    platform = "linux-arm64";
    buildPlatform = "linux/arm64";
    buildArch = "arm64";
    transport = "${podman} --connection openclaw-sandbox";
    transportExec = "exec ${podman} --connection openclaw-sandbox";
    imageBuildPrelude = ''
      deadline=$((SECONDS + 180))
      while ! info=$(${podman} --connection openclaw-sandbox info --format json 2>/dev/null) ||
        ! printf '%s\n' "$info" | ${jq} -e '.host.security.rootless == true' >/dev/null 2>&1; do
        if (( SECONDS >= deadline )); then
          printf '%s\n' "openclaw-sandbox was not reachable as a rootless Podman connection within 180 seconds" >&2
          exit 1
        fi
        sleep 2
      done
    '';
  };
  camofoxAgent = pkgs.writeShellApplication {
    name = "camofox-browser-agent";
    runtimeInputs = [
      pkgs.podman
      pkgs.jq
      pkgs.coreutils
      config.programs.openclaw.package
    ];
    text = ''
            set -euo pipefail
            openclaw=${lib.escapeShellArg openclaw}
            image_build=${lib.escapeShellArg (lib.getExe common.imageBuild)}

            if ! access_key=$("$openclaw" secrets store get CAMOFOX_ACCESS_KEY --plain 2>/dev/null); then
              printf '%s\n' "refusing to start Camofox: could not retrieve CAMOFOX_ACCESS_KEY from the OpenClaw Secret Store" >&2
              exit 1
            fi
            if [[ -z "$access_key" ]]; then
              printf '%s\n' "refusing to start Camofox: CAMOFOX_ACCESS_KEY is empty" >&2
              exit 1
            fi
            export CAMOFOX_ACCESS_KEY="$access_key"
            unset CAMOFOX_API_KEY

            # image_build performs the rootless openclaw-sandbox readiness check before
            # inspecting or building the image, and before any network/container operation.
            "$image_build"

            ${podman} --connection openclaw-sandbox network inspect openclaw-camofox >/dev/null 2>&1 ||
              ${podman} --connection openclaw-sandbox network create --driver bridge openclaw-camofox >/dev/null
            ${podman} --connection openclaw-sandbox rm --force openclaw-camofox-browser >/dev/null 2>&1 || true

            # Blanket capability removal breaks Firefox's sandbox; these drops remain confined to the rootless user namespace.
            exec ${podman} --connection openclaw-sandbox run --rm \
               --name openclaw-camofox-browser \
               --init \
               --network openclaw-camofox \
              --memory 2g \
              --cpus 2 \
      ${common.commonRunArgs}
    '';
  };
in
{
  home.packages = [ common.imageBuild ];
  home.activation.camofoxDirectories = common.activation;
  launchd.agents.camofox-browser = {
    enable = true;
    domain = "gui";
    config = {
      ProgramArguments = [ (lib.getExe camofoxAgent) ];
      RunAtLoad = true;
      KeepAlive = true;
      ProcessType = "Background";
      Umask = 63;
      ThrottleInterval = 10;
      StandardOutPath = "${homeDirectory}/.camofox/logs/launchd.log";
      StandardErrorPath = "${homeDirectory}/.camofox/logs/launchd.error.log";
    };
  };
}
