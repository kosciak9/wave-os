{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:

let
  cfg = config.services.slack-mirror;
  home = config.home.homeDirectory;
  component = "slack-mirror";
  containerName = "wave-slack-mirror";
  networkName = "wave-slack-mirror";
  image = pkgs.slack-mirror-image;
  secret = name: lib.escapeShellArg osConfig.sops.secrets."slack-mirror/${name}".path;
  machineCheck = pkgs.writeShellApplication {
    name = "slack-mirror-machine-check";
    runtimeInputs = [
      pkgs.podman
      pkgs.jq
    ];
    text = ''
      machine=${lib.escapeShellArg cfg.machineName}
      podman machine inspect "$machine" |
        jq -e 'length == 1 and .[0].Rootful == false' >/dev/null
      podman --connection "$machine" info --format json |
        jq -e '.host.security.rootless == true' >/dev/null
    '';
  };
  supervisor = pkgs.writeShellApplication {
    name = "slack-mirror-supervisor";
    runtimeInputs = [
      pkgs.podman
      pkgs.jq
      pkgs.python3
      pkgs.coreutils
    ];
    text = ''
      machine=${lib.escapeShellArg cfg.machineName}
      volume=${lib.escapeShellArg cfg.dataVolume}
      mode=${if cfg.sync.enable then "online" else "offline"}

      if ! state=$(podman machine inspect "$machine" | jq -er '
        if length == 1 and .[0].Rootful == false then .[0].State else error("rootful machine") end'); then
        printf '%s\n' "Provision a rootless $machine machine before starting Slack mirror" >&2
        exit 1
      fi
      if [[ "$state" == stopped ]]; then
        if ! podman machine start --update-connection=false "$machine"; then
          printf '%s\n' "Could not start $machine; Podman permits only one active managed VM. Other machines are left running." >&2
          exit 1
        fi
      fi
      deadline=$((SECONDS + 180))
      until ${lib.getExe machineCheck} >/dev/null 2>&1; do
        if (( SECONDS >= deadline )); then
          printf '%s\n' "$machine rootless connection was not ready within 180 seconds" >&2
          exit 1
        fi
        sleep 2
      done
      transport=(podman --connection "$machine")
      ${lib.getExe image} "$machine"

      if "''${transport[@]}" container exists ${containerName}; then
        stale_id=$("''${transport[@]}" container inspect ${containerName} |
          jq -er '.[0] | if .Config.Labels["io.wave-os.component"] == "${component}"
            then .Id else error("container is not owned by Slack mirror") end')
        "''${transport[@]}" rm --force "$stale_id" >/dev/null
      fi
      if "''${transport[@]}" network exists ${networkName}; then
        "''${transport[@]}" network inspect ${networkName} |
          jq -e '.[0].labels["io.wave-os.component"] == "${component}"' >/dev/null
      else
        "''${transport[@]}" network create --driver bridge \
          --label io.wave-os.component=${component} ${networkName} >/dev/null
      fi
      volume_options=rw,Z
      if "''${transport[@]}" volume exists "$volume"; then
        "''${transport[@]}" volume inspect "$volume" |
          jq -e '.[0].Labels["io.wave-os.component"] == "${component}"' >/dev/null
      else
        "''${transport[@]}" volume create --label io.wave-os.component=${component} "$volume" >/dev/null
        # Only initialize ownership on this service's newly created named volume.
        volume_options=rw,Z,U
      fi

      # Restrict only the verified dedicated volume, including older 0755 volumes.
      "''${transport[@]}" run --rm --pull=never --network none --http-proxy=false \
        --label io.wave-os.component=${component} \
        --user 65532:65532 --userns=keep-id:uid=65532,gid=65532 \
        --cap-drop ALL --security-opt no-new-privileges --read-only \
        --pids-limit 32 --memory 64m --cpus 0.25 \
        --volume "$volume:/data:$volume_options" \
        --entrypoint /bin/chmod ${lib.escapeShellArg image.imageName} 0700 /data

      secrets_to_check=(wave-slack-mirror-mcp-token)
      session_args=(--offline)
      if [[ "$mode" == online ]]; then
        secrets_to_check+=(wave-slack-mirror-session)
        session_args=(--session-file /run/secrets/session.json)
      fi
      for secret in "''${secrets_to_check[@]}"; do
        if "''${transport[@]}" secret exists "$secret"; then
          "''${transport[@]}" secret inspect "$secret" |
            jq -e '.[0].Spec.Labels["io.wave-os.component"] == "${component}"' >/dev/null
        else
          status=$?
          if (( status != 1 )); then
            exit "$status"
          fi
        fi
      done
      session_mount=()
      if [[ "$mode" == online ]]; then
        "''${transport[@]}" secret create --replace --label io.wave-os.component=${component} \
          wave-slack-mirror-session ${lib.optionalString cfg.sync.enable (secret "session.json")} >/dev/null
        session_mount=(--secret "source=wave-slack-mirror-session,type=mount,target=session.json,uid=65532,gid=65532,mode=0600")
      fi
      "''${transport[@]}" secret create --replace --label io.wave-os.component=${component} \
        wave-slack-mirror-mcp-token ${secret "mcp-token"} >/dev/null

      instance=$(python3 -c 'import secrets; print(secrets.token_hex(16))')
      child=""
      cleanup() {
        local container_id
        if container_id=$("''${transport[@]}" container inspect ${containerName} 2>/dev/null |
          jq -er --arg instance "$instance" '.[0] |
            if .Config.Labels["io.wave-os.component"] == "${component}" and
               .Config.Labels["io.wave-os.supervisor"] == $instance
            then .Id else empty end'); then
          "''${transport[@]}" stop --time 20 "$container_id" >/dev/null 2>&1 || true
        fi
        if [[ -n "$child" ]]; then
          wait "$child" || true
        fi
      }
      trap cleanup EXIT
      trap 'exit 143' TERM
      trap 'exit 130' INT
      "''${transport[@]}" run --rm --name ${containerName} \
        --label io.wave-os.component=${component} \
        --label "io.wave-os.supervisor=$instance" \
        --pull=never --network ${networkName} --http-proxy=false \
        --publish 127.0.0.1:${toString cfg.port}:19440 \
        --user 65532:65532 --userns=keep-id:uid=65532,gid=65532 \
        --cap-drop ALL --security-opt no-new-privileges \
        --read-only --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m,mode=1777 \
        --pids-limit 128 --memory 512m --cpus 1 \
        --volume "$volume:/data:rw,Z" \
        "''${session_mount[@]}" \
        --secret source=wave-slack-mirror-mcp-token,type=mount,target=mcp-token,uid=65532,gid=65532,mode=0600 \
        ${lib.escapeShellArg image.imageName} \
        serve --database /data/mirror.db \
        --mcp-token-file /run/secrets/mcp-token --listen 0.0.0.0:19440 "''${session_args[@]}" &
      child=$!
      wait "$child"
    '';
  };
in
{
  options.services.slack-mirror = {
    enable = lib.mkEnableOption "the independent authenticated Slack mirror service";
    sync.enable = lib.mkEnableOption "Slack synchronization (requires a separately provisioned web session)";
    port = lib.mkOption {
      type = lib.types.port;
      default = 19440;
      description = "Loopback-only host port for the authenticated MCP server.";
    };
    machineName = lib.mkOption {
      type = lib.types.strMatching "[a-zA-Z0-9][a-zA-Z0-9_-]*";
      default = "wave-services";
      description = "Pre-provisioned rootless Podman machine and connection for independent services.";
    };
    dataVolume = lib.mkOption {
      type = lib.types.strMatching "[a-zA-Z0-9][a-zA-Z0-9_.-]*";
      default = "wave-slack-mirror-data";
      description = "Persistent dedicated named volume; retained across restarts and upgrades.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.isDarwin;
        message = "Slack mirror launchd supervision requires Darwin.";
      }
    ];
    home.packages = [
      pkgs.slack-mirror
      image
      machineCheck
    ];
    home.activation.slackMirrorLogs =
      lib.hm.dag.entryBetween [ "setupLaunchAgents" ] [ "writeBoundary" ]
        ''
          run mkdir -p ${lib.escapeShellArg "${home}/.local/state/slack-mirror"}
          run chmod 0700 ${lib.escapeShellArg "${home}/.local/state/slack-mirror"}
        '';
    launchd.agents.slack-mirror = {
      enable = true;
      domain = "user";
      config = {
        ProgramArguments = [ (lib.getExe supervisor) ];
        RunAtLoad = true;
        KeepAlive = true;
        ProcessType = "Background";
        ThrottleInterval = 30;
        ExitTimeOut = 30;
        Umask = 63;
        StandardOutPath = "${home}/.local/state/slack-mirror/launchd.log";
        StandardErrorPath = "${home}/.local/state/slack-mirror/launchd.error.log";
      };
    };
  };
}
