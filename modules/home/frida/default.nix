{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  cfg = config.services.frida;
  home = config.home.homeDirectory;
  logDirectory = "${home}/.local/state/frida";
  component = "frida";
  containerName = "wave-frida";
  volume = "wave-frida-state";
  agentConfig = pkgs.writeText "frida-house-agents.config.ts" ''
    export default {
      prompt: ${builtins.toJSON ''
        Jesteś Fridą, asystentką domową wspólnej grupy na Telegramie.
        Pomagasz domownikom organizować codzienne sprawy, listy zakupów i obowiązki.
        Odpowiadasz po polsku, krótko i praktycznie. Rozróżniasz osoby piszące na grupie;
        gdy nie wiesz, do kogo należy informacja, pytasz zamiast zgadywać.
        Nie masz dostępu do prywatnej pamięci Alfreda, jego Slacka ani kont zawodowych.
        Nie twierdzisz, że wykonałaś działanie w zewnętrznym systemie, jeśli nie masz
        odpowiedniego narzędzia i potwierdzenia wykonania.
      ''},
      model: { provider: "openai-codex", modelId: "gpt-6.1-sol", thinkingLevel: "medium" },
      telegram: { chatId: Number(process.env.TELEGRAM_CHAT_ID) },
      whisperUrl: "http://host.containers.internal:18080/v1/audio/transcriptions",
      stateDir: "/data/state",
    };
  '';
  supervisor = pkgs.writeShellApplication {
    name = "frida-supervisor";
    runtimeInputs = [
      pkgs.podman
      pkgs.jq
      pkgs.coreutils
    ];
    text = ''
      machine=${lib.escapeShellArg config.services.alfred.machineName}
      env_file=${lib.escapeShellArg osConfig.sops.secrets."frida/env".path}
      image=${lib.escapeShellArg config.services.alfred.image}

      if ! grep -q '^TELEGRAM_BOT_TOKEN=.' "$env_file" ||
        ! grep -q '^TELEGRAM_CHAT_ID=-[0-9]\+$' "$env_file"; then
        printf '%s\n' 'frida/env must set TELEGRAM_BOT_TOKEN and a numeric group TELEGRAM_CHAT_ID' >&2
        exit 1
      fi
      state=$(podman machine inspect "$machine" | jq -er '
        if length == 1 and .[0].Rootful == false then .[0].State else error("rootful machine") end')
      if [[ "$state" == stopped ]]; then
        podman machine start --update-connection=false "$machine"
      fi
      transport=(podman --connection "$machine")
      deadline=$((SECONDS + 180))
      until "''${transport[@]}" info --format json 2>/dev/null |
        jq -e '.host.security.rootless == true' >/dev/null; do
        if (( SECONDS >= deadline )); then
          printf '%s\n' "$machine rootless connection was not ready within 180 seconds" >&2
          exit 1
        fi
        sleep 2
      done
      if "''${transport[@]}" container exists ${containerName}; then
        stale_id=$("''${transport[@]}" container inspect ${containerName} |
          jq -er '.[0] | if .Config.Labels["io.wave-os.component"] == "${component}"
            then .Id else error("container is not owned by Frida") end')
        "''${transport[@]}" rm --force "$stale_id" >/dev/null
      fi
      if "''${transport[@]}" volume exists ${volume}; then
        "''${transport[@]}" volume inspect ${volume} |
          jq -e '.[0].Labels["io.wave-os.component"] == "${component}"' >/dev/null
      else
        "''${transport[@]}" volume create --label io.wave-os.component=${component} ${volume} >/dev/null
      fi
      if "''${transport[@]}" secret exists wave-frida-config; then
        "''${transport[@]}" secret inspect wave-frida-config |
          jq -e '.[0].Spec.Labels["io.wave-os.component"] == "${component}"' >/dev/null
      fi
      "''${transport[@]}" secret create --replace --label io.wave-os.component=${component} \
        wave-frida-config ${agentConfig} >/dev/null

      instance=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
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
        --pull=missing --network bridge --http-proxy=false \
        --cap-drop ALL --security-opt no-new-privileges \
        --read-only --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m,mode=1777 \
        --pids-limit 256 --memory 1g --cpus 2 \
        --env-file "$env_file" \
        --volume ${volume}:/data/state:rw,Z \
        --secret source=wave-frida-config,type=mount,target=/data/house-agents.config.ts,uid=1000,gid=1000,mode=0400 \
        "$image" &
      child=$!
      wait "$child"
    '';
  };
in
{
  options.services.frida.enable = lib.mkEnableOption "Frida, the household assistant on Telegram";

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.isDarwin;
        message = "Frida launchd supervision requires Darwin.";
      }
    ];
    home.activation.frida = lib.hm.dag.entryBetween [ "setupLaunchAgents" ] [ "writeBoundary" ] ''
      run install -d -m 0700 ${lib.escapeShellArg logDirectory}
    '';
    launchd.agents.frida = {
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
        StandardOutPath = "${logDirectory}/launchd.log";
        StandardErrorPath = "${logDirectory}/launchd.error.log";
      };
    };
  };
}
