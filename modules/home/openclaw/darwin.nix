{
  config,
  lib,
  pkgs,
  ...
}:

let
  homeDirectory = config.home.homeDirectory;
  podman = lib.getExe pkgs.podman;
  curl = lib.getExe pkgs.curl;
  openclaw = lib.getExe config.programs.openclaw.package;
  install = lib.getExe' pkgs.coreutils "install";
  sandboxMachineValidation = ''
    validate_machine() {
      local machine_config machine_list machine_metadata

      if ! machine_config=$("$podman" machine inspect \
        --format '{{.Rootful}}\t{{.Resources.CPUs}}\t{{.Resources.Memory}}\t{{.Resources.DiskSize}}' \
        openclaw-sandbox 2>/dev/null); then
        printf '%s\n' "openclaw-sandbox machine inspection failed" >&2
        exit 1
      fi
      if [[ "$machine_config" != $'false\t4\t6144\t40' ]]; then
        printf '%s\n' \
          "openclaw-sandbox machine configuration drift detected: expected Rootful=false, CPUs=4, Memory=6144, DiskSize=40; found $machine_config" >&2
        exit 1
      fi

      if ! machine_list=$("$podman" machine list --format json 2>/dev/null); then
        printf '%s\n' "openclaw-sandbox machine metadata inspection failed" >&2
        exit 1
      fi
      if ! jq -e \
        '[.[] | select(.Name == "openclaw-sandbox")] | length == 1' \
        <<<"$machine_list" >/dev/null; then
        printf '%s\n' \
          "openclaw-sandbox machine metadata is absent or ambiguous" >&2
        exit 1
      fi
      if ! machine_metadata=$(jq -er \
        '[.[] | select(.Name == "openclaw-sandbox")] | .[0] |
          (.Swap? // null) as $swap |
          ($swap |
            if type == "number" then .
            elif type == "string" and test("^[0-9]+$") then tonumber
            else null
            end) as $normalized_swap |
          if ((.VMType? | type) != "string" or .VMType != "applehv" or
              $normalized_swap != 0) then
            error("invalid VMType or Swap")
          else
            [ .VMType, "0" ] | @tsv
          end' \
        <<<"$machine_list" 2>/dev/null) || [[ "$machine_metadata" != $'applehv\t0' ]]; then
        printf '%s\n' \
          "openclaw-sandbox machine metadata drift detected: expected VMType=applehv, Swap=0" >&2
        exit 1
      fi
    }
  '';

  sandboxBootstrap = pkgs.writeShellApplication {
    name = "openclaw-sandbox-bootstrap";
    runtimeInputs = [
      pkgs.podman
      pkgs.jq
    ];
    text = ''
      set -euo pipefail

      podman=${podman}
      ${sandboxMachineValidation}
      default_connection=""
      while IFS=$'\t' read -r connection is_default; do
        if [[ "$is_default" == "true" ]]; then
          default_connection="$connection"
          break
        fi
      done < <("$podman" system connection list --format '{{.Name}}\t{{.Default}}')

      restore_default() {
        if [[ -n "$default_connection" ]]; then
          "$podman" system connection default "$default_connection" >/dev/null
        fi
      }
      trap restore_default EXIT

      if ! "$podman" machine inspect openclaw-sandbox >/dev/null 2>&1; then
        CONTAINERS_MACHINE_PROVIDER=applehv \
          "$podman" machine init \
            --rootful=false \
            --cpus 4 \
            --memory 6144 \
            --disk-size 40 \
            --swap 0 \
            openclaw-sandbox
      fi
      validate_machine
    '';
  };

  sandboxImageBuild = pkgs.writeShellApplication {
    name = "openclaw-sandbox-image-build";
    runtimeInputs = [ pkgs.podman ];
    text = ''
      set -euo pipefail

      podman=${podman}
      if ! "$podman" --connection openclaw-sandbox info >/dev/null 2>&1; then
        printf '%s\n' \
          "openclaw-sandbox must exist and be running before building the image" >&2
        exit 1
      fi

      exec "$podman" --connection openclaw-sandbox build \
        --file ${pkgs.openclaw-sandbox-context}/scripts/docker/sandbox/Dockerfile \
        --tag openclaw-sandbox:bookworm-slim \
        ${pkgs.openclaw-sandbox-context}
    '';
  };

  sandboxMachineAgent = pkgs.writeShellApplication {
    name = "openclaw-sandbox-machine-agent";
    runtimeInputs = [
      pkgs.podman
      pkgs.jq
    ];
    text = ''
      set -euo pipefail

      podman=${podman}
      ${sandboxMachineValidation}
      machine_state=""
      inspect_deadline=$((SECONDS + 120))
      until machine_state=$("$podman" machine inspect \
        --format '{{.State}}' openclaw-sandbox 2>/dev/null); do
        if (( SECONDS >= inspect_deadline )); then
          printf '%s\n' \
            "timed out waiting for openclaw-sandbox machine inspection" >&2
          exit 1
        fi
        sleep 2
      done

      validate_machine

      attempt=1
      while (( attempt <= 3 )); do
        attempt_failed=false
        if ! machine_state=$("$podman" machine inspect \
          --format '{{.State}}' openclaw-sandbox 2>/dev/null); then
          attempt_failed=true
        elif [[ "$machine_state" != "running" ]] && \
          ! "$podman" machine start openclaw-sandbox; then
          attempt_failed=true
        fi

        if [[ "$attempt_failed" == false ]]; then
          deadline=$((SECONDS + 120))
          until "$podman" --connection openclaw-sandbox info >/dev/null 2>&1; do
            if (( SECONDS >= deadline )); then
              attempt_failed=true
              break
            fi
            sleep 2
          done
        fi

        if [[ "$attempt_failed" == false ]]; then
          exit 0
        fi

        printf 'openclaw-sandbox startup attempt %d of 3 failed\n' "$attempt" >&2
        "$podman" machine stop openclaw-sandbox >/dev/null 2>&1 || true
        if (( attempt < 3 )); then
          sleep 5
        fi
        attempt=$((attempt + 1))
      done

      printf '%s\n' \
        "openclaw-sandbox failed to become reachable after 3 startup attempts" >&2
      exit 1
    '';
  };

  appAgent = pkgs.writeShellApplication {
    name = "openclaw-app-agent";
    runtimeInputs = [
      pkgs.curl
      config.programs.openclaw.package
    ];
    text = ''
      set -euo pipefail

      curl=${curl}
      openclaw=${lib.escapeShellArg openclaw}
      app_binary=${lib.escapeShellArg "${homeDirectory}/Applications/Home Manager Apps/OpenClaw.app/Contents/MacOS/OpenClaw"}
      deadline=$((SECONDS + 120))
      until "$curl" --fail --silent --show-error --max-time 5 \
        http://127.0.0.1:18789/healthz >/dev/null 2>&1 && \
        "$curl" --fail --silent --show-error --max-time 5 \
          http://127.0.0.1:18789/startupz >/dev/null 2>&1; do
        if (( SECONDS >= deadline )); then
          printf '%s\n' "timed out waiting for OpenClaw readiness" >&2
          exit 1
        fi
        sleep 2
      done

      if ! token=$("$openclaw" secrets store get OPENCLAW_GATEWAY_TOKEN --plain); then
        printf '%s\n' "refusing to start OpenClaw.app: could not retrieve OPENCLAW_GATEWAY_TOKEN from the store" >&2
        exit 1
      fi
      if [[ -z "$token" ]]; then
        printf '%s\n' "refusing to start OpenClaw.app: OPENCLAW_GATEWAY_TOKEN is empty" >&2
        exit 1
      fi
      export OPENCLAW_GATEWAY_TOKEN="$token"
      exec "$app_binary"
    '';
  };
in
{
  home.packages = [
    sandboxBootstrap
    sandboxImageBuild
    pkgs.mac-apps-mcp-host
  ];

  home.activation.openclawLogDirectory = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    ${install} -d -m 0700 -- "${homeDirectory}/Library/Logs/OpenClaw"
  '';

  launchd.agents.openclaw-sandbox-machine = {
    enable = true;
    domain = "gui";
    config = {
      ProgramArguments = [ (lib.getExe sandboxMachineAgent) ];
      RunAtLoad = true;
      KeepAlive = false;
      Umask = 63;
      ProcessType = "Background";
      StandardOutPath = "${homeDirectory}/Library/Logs/OpenClaw/sandbox-machine.log";
      StandardErrorPath = "${homeDirectory}/Library/Logs/OpenClaw/sandbox-machine.error.log";
    };
  };

  launchd.agents.openclaw-app = {
    enable = true;
    domain = "gui";
    config = {
      ProgramArguments = [ (lib.getExe appAgent) ];
      RunAtLoad = true;
      KeepAlive = false;
      Umask = 63;
      ProcessType = "Background";
      StandardOutPath = "${homeDirectory}/Library/Logs/OpenClaw/app.log";
      StandardErrorPath = "${homeDirectory}/Library/Logs/OpenClaw/app.error.log";
    };
  };
}
