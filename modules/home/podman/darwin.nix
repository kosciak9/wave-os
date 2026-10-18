{
  config,
  lib,
  pkgs,
  ...
}:

let
  homeDirectory = config.home.homeDirectory;
  podman = lib.getExe pkgs.podman;
  sandboxMachineChecker = pkgs.openclaw-sandbox-machine-check;
  sandboxMachineName = lib.escapeShellArg sandboxMachineChecker.passthru.machineName;
  install = lib.getExe' pkgs.coreutils "install";

  sandboxMachineAgent = pkgs.writeShellApplication {
    name = "openclaw-sandbox-machine-agent";
    runtimeInputs = [
      pkgs.podman
      sandboxMachineChecker
    ];
    text = ''
      set -euo pipefail

      podman=${podman}
      machine_checker=${lib.getExe sandboxMachineChecker}
      machine_name=${sandboxMachineName}
      machine_state=""
      wait_deadline=$((SECONDS + 120))
      until machine_state=$("$podman" machine inspect \
        --format '{{.State}}' "$machine_name" 2>/dev/null); do
        if (( SECONDS >= wait_deadline )); then
          printf '%s\n' \
            "timed out waiting for openclaw-sandbox machine inspection" >&2
          exit 1
        fi
        sleep 5
      done

      recover_machine() {
        local attempt attempt_failed deadline

        for attempt in 1 2 3; do
          attempt_failed=false
          "$machine_checker"
          if ! machine_state=$("$podman" machine inspect \
            --format '{{.State}}' "$machine_name" 2>/dev/null); then
            attempt_failed=true
          elif [[ "$machine_state" != "running" ]]; then
            if ! "$podman" machine start "$machine_name" >/dev/null 2>&1; then
              attempt_failed=true
            fi
          fi

          if [[ "$attempt_failed" == false ]]; then
            deadline=$((SECONDS + 120))
            until "$podman" --connection openclaw-sandbox info >/dev/null 2>&1; do
              if (( SECONDS >= deadline )); then
                attempt_failed=true
                break
              fi
              sleep 5
            done
          fi

          if [[ "$attempt_failed" == false ]]; then
            return 0
          fi

          printf 'openclaw-sandbox recovery attempt %d of 3 failed\n' "$attempt" >&2
          "$podman" machine stop "$machine_name" >/dev/null 2>&1 || true
          if (( attempt < 3 )); then
            sleep 10
          fi
        done

        printf '%s\n' \
          "openclaw-sandbox failed to become reachable after 3 recovery attempts" >&2
        return 1
      }

      "$machine_checker"
      recover_machine
      while :; do
        sleep 30
        "$machine_checker"
        if machine_state=$("$podman" machine inspect \
          --format '{{.State}}' "$machine_name" 2>/dev/null) && \
          [[ "$machine_state" == "running" ]] && \
          "$podman" --connection openclaw-sandbox info >/dev/null 2>&1; then
          continue
        fi
        recover_machine
      done
    '';
  };

in
{
  # Keep the shared VM's launchd identity and log paths stable for existing services.
  home.activation.podmanMachineLogDirectory =
    lib.hm.dag.entryBetween [ "setupLaunchAgents" ] [ "writeBoundary" ]
      ''
        ${install} -d -m 0700 -- "${homeDirectory}/Library/Logs/OpenClaw"
      '';

  home.activation.podmanDefaultConnection =
    lib.hm.dag.entryBetween [ "setupLaunchAgents" ] [ "writeBoundary" ]
      ''
        if ! ${podman} system connection list --format json |
          ${lib.getExe pkgs.jq} -e --arg name ${sandboxMachineName} \
            'any(.[]; .Name == $name and .Default == true)' >/dev/null; then
          run ${podman} system connection default ${sandboxMachineName}
        fi
      '';

  launchd.agents.openclaw-sandbox-machine = {
    enable = true;
    domain = "gui";
    config = {
      ProgramArguments = [ (lib.getExe sandboxMachineAgent) ];
      RunAtLoad = true;
      KeepAlive = {
        SuccessfulExit = false;
      };
      Umask = 63;
      ProcessType = "Background";
      StandardOutPath = "${homeDirectory}/Library/Logs/OpenClaw/sandbox-machine.log";
      StandardErrorPath = "${homeDirectory}/Library/Logs/OpenClaw/sandbox-machine.error.log";
    };
  };

}
