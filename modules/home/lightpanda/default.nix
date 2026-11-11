{
  lib,
  pkgs,
  ...
}:

let
  podman = lib.getExe pkgs.podman;
  image = "docker.io/lightpanda/browser:1.0.3@sha256:d901cf2374b8372935f690da1db896b8c1d5317022d462fdceeaf4813e8be724";
  lightpandaAgent = pkgs.writeShellApplication {
    name = "lightpanda-mcp-agent";
    runtimeInputs = [ pkgs.podman ];
    text = ''
      set -euo pipefail
      ${podman} network inspect openclaw-lightpanda >/dev/null 2>&1 ||
        ${podman} network create --driver bridge openclaw-lightpanda >/dev/null
      ${podman} rm --force openclaw-lightpanda >/dev/null 2>&1 || true

      # Every MCP session is an isolated page and cookie jar; nothing persists.
      exec ${podman} run --rm \
        --name openclaw-lightpanda \
        --pull=missing \
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
  systemd.user.services.lightpanda-mcp = {
    Unit.Description = "Lightpanda MCP browser";
    Service = {
      ExecStart = lib.getExe lightpandaAgent;
      Restart = "always";
      RestartSec = 10;
      UMask = "0077";
    };
    Install.WantedBy = [ "default.target" ];
  };
}
