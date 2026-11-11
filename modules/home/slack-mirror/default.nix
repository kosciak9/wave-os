{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:

let
  cfg = config.services.slack-mirror;
  component = "slack-mirror";
  containerName = "wave-slack-mirror";
  networkName = "wave-slack-mirror";
  image = pkgs.slack-mirror-image;
  secret = name: lib.escapeShellArg osConfig.sops.secrets."slack-mirror/${name}".path;
  supervisor = pkgs.writeShellApplication {
    name = "slack-mirror-supervisor";
    runtimeInputs = [
      pkgs.podman
      pkgs.jq
      pkgs.python3
      pkgs.coreutils
    ];
    text = ''
      volume=${lib.escapeShellArg cfg.dataVolume}
      mode=${if cfg.sync.enable then "online" else "offline"}

      ${lib.getExe image}

      if podman container exists ${containerName}; then
        stale_id=$(podman container inspect ${containerName} |
          jq -er '.[0] | if .Config.Labels["io.wave-os.component"] == "${component}"
            then .Id else error("container is not owned by Slack mirror") end')
        podman rm --force "$stale_id" >/dev/null
      fi
      if podman network exists ${networkName}; then
        podman network inspect ${networkName} |
          jq -e '.[0].labels["io.wave-os.component"] == "${component}"' >/dev/null
      else
        podman network create --driver bridge \
          --label io.wave-os.component=${component} ${networkName} >/dev/null
      fi
      volume_options=rw,Z
      if podman volume exists "$volume"; then
        podman volume inspect "$volume" |
          jq -e '.[0].Labels["io.wave-os.component"] == "${component}"' >/dev/null
      else
        podman volume create --label io.wave-os.component=${component} "$volume" >/dev/null
        # Only initialize ownership on this service's newly created named volume.
        volume_options=rw,Z,U
      fi

      # Restrict only the verified dedicated volume, including older 0755 volumes.
      podman run --rm --pull=never --network none --http-proxy=false \
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
        if podman secret exists "$secret"; then
          podman secret inspect "$secret" |
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
        podman secret create --replace --label io.wave-os.component=${component} \
          wave-slack-mirror-session ${lib.optionalString cfg.sync.enable (secret "session.json")} >/dev/null
        session_mount=(--secret "source=wave-slack-mirror-session,type=mount,target=session.json,uid=65532,gid=65532,mode=0600")
      fi
      podman secret create --replace --label io.wave-os.component=${component} \
        wave-slack-mirror-mcp-token ${secret "mcp-token"} >/dev/null

      instance=$(python3 -c 'import secrets; print(secrets.token_hex(16))')
      child=""
      cleanup() {
        local container_id
        if container_id=$(podman container inspect ${containerName} 2>/dev/null |
          jq -er --arg instance "$instance" '.[0] |
            if .Config.Labels["io.wave-os.component"] == "${component}" and
               .Config.Labels["io.wave-os.supervisor"] == $instance
            then .Id else empty end'); then
          podman stop --time 20 "$container_id" >/dev/null 2>&1 || true
        fi
        if [[ -n "$child" ]]; then
          wait "$child" || true
        fi
      }
      trap cleanup EXIT
      trap 'exit 143' TERM
      trap 'exit 130' INT
      podman run --rm --name ${containerName} \
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
    dataVolume = lib.mkOption {
      type = lib.types.strMatching "[a-zA-Z0-9][a-zA-Z0-9_.-]*";
      default = "wave-slack-mirror-data";
      description = "Persistent dedicated named volume; retained across restarts and upgrades.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      pkgs.slack-mirror
      image
    ];
    systemd.user.services.slack-mirror = {
      Unit.Description = "Slack mirror";
      Service = {
        ExecStart = lib.getExe supervisor;
        Restart = "always";
        RestartSec = 30;
        TimeoutStopSec = 30;
        UMask = "0077";
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
