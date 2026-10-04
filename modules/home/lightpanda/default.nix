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
  image = "docker.io/lightpanda/browser:1.0.0@sha256:5b84708cb3d9bef841aba4a4cd299f4de0609ac1bd7d4c6fbfcbf168d56b685e";
  lightpandaAgent = pkgs.writeShellApplication {
    name = "lightpanda-mcp-agent";
    runtimeInputs = [
      pkgs.podman
      pkgs.jq
      pkgs.coreutils
    ];
    text = ''
      set -euo pipefail
      deadline=$((SECONDS + 180))
      while ! info=$(${podman} --connection openclaw-sandbox info --format json 2>/dev/null) ||
        ! printf '%s\n' "$info" | ${jq} -e '.host.security.rootless == true' >/dev/null 2>&1; do
        if (( SECONDS >= deadline )); then
          printf '%s\n' "openclaw-sandbox was not reachable as a rootless Podman connection within 180 seconds" >&2
          exit 1
        fi
        sleep 2
      done

      ${podman} --connection openclaw-sandbox network inspect openclaw-lightpanda >/dev/null 2>&1 ||
        ${podman} --connection openclaw-sandbox network create --driver bridge openclaw-lightpanda >/dev/null
      ${podman} --connection openclaw-sandbox rm --force openclaw-lightpanda >/dev/null 2>&1 || true

      # Every MCP session is an isolated page and cookie jar; nothing persists.
      exec ${podman} --connection openclaw-sandbox run --rm \
        --name openclaw-lightpanda \
        --pull=missing \
        --platform linux/arm64 \
        --network openclaw-lightpanda \
        --publish 127.0.0.1:9378:9378 \
        --read-only \
        --tmpfs /tmp \
        --cap-drop ALL \
        --security-opt no-new-privileges \
        --pids-limit 256 \
        --memory 1g \
        --cpus 1 \
        --env HOME=/tmp \
        --env LIGHTPANDA_DISABLE_TELEMETRY=true \
        ${lib.escapeShellArg image} \
        /bin/lightpanda mcp \
        --host 0.0.0.0 \
        --port 9378 \
        --block-private-networks \
        --block-cidrs 100.64.0.0/10
    '';
  };
in
{
  launchd.agents.lightpanda-mcp = {
    enable = true;
    domain = "gui";
    config = {
      ProgramArguments = [ (lib.getExe lightpandaAgent) ];
      RunAtLoad = true;
      KeepAlive = true;
      ProcessType = "Background";
      Umask = 63;
      ThrottleInterval = 10;
      StandardOutPath = "${homeDirectory}/Library/Logs/OpenClaw/lightpanda.log";
      StandardErrorPath = "${homeDirectory}/Library/Logs/OpenClaw/lightpanda.error.log";
    };
  };
}
