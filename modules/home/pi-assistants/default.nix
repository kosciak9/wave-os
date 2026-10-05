{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.pi-telegram-test;
  state = "${config.xdg.stateHome}/pi-telegram-test";
  imageBuilder = pkgs.pi-assistants-image;
  openclaw = lib.getExe config.programs.openclaw.package;
  runner = pkgs.writeShellApplication {
    name = "pi-telegram-test-run";
    runtimeInputs = [
      pkgs.podman
      pkgs.jq
      pkgs.coreutils
    ];
    text = ''
      set -euo pipefail
      umask 077
      token_file=${lib.escapeShellArg cfg.tokenFile}
      owner_file=${lib.escapeShellArg cfg.ownerIdFile}
      env_file=${lib.escapeShellArg cfg.modelEnvFile}
      state_dir=${lib.escapeShellArg state}

      # Installing the service is safe before the owner supplies its test token.
      if [[ ! -e "$token_file" && ! -L "$token_file" ]]; then
        printf '%s\n' 'Pi test bot is not configured: add its private token file, then kickstart the service.' >&2
        exit 0
      fi
      private_file() {
        [[ ! -L "$1" && -f "$1" && -r "$1" ]] &&
          [[ "$(/usr/bin/stat -f %Lp "$1")" == 600 ]] &&
          [[ "$(/usr/bin/stat -f %u "$1")" == "$(/usr/bin/id -u)" ]]
      }
      for file in "$token_file" "$owner_file"; do
        if ! private_file "$file"; then
          printf '%s\n' 'Pi test token and owner ID must be owned, mode-0600 regular files.' >&2
          exit 1
        fi
      done
      if [[ -L "$state_dir" || ! -d "$state_dir" ]] ||
        [[ "$(/usr/bin/stat -f %Lp "$state_dir")" != 700 ]] ||
        [[ "$(/usr/bin/stat -f %u "$state_dir")" != "$(/usr/bin/id -u)" ]]; then
        printf '%s\n' 'Pi test state must be an owned, mode-0700 directory.' >&2
        exit 1
      fi

      config_file=$(mktemp "$state_dir/config.XXXXXX")
      cid_file="$config_file.cid"
      cleanup() { rm -f -- "$config_file" "$cid_file"; }
      trap cleanup EXIT
      trap 'exit 0' INT TERM
      if ! jq -en --rawfile token "$token_file" --rawfile owner "$owner_file" \
        --arg provider ${lib.escapeShellArg cfg.provider} --arg model ${lib.escapeShellArg cfg.model} '
          ($token | sub("\\n$"; "")) as $token |
          ($owner | sub("\\n$"; "")) as $owner |
          select($token | test("^[0-9]+:[A-Za-z0-9_-]+$")) |
          select($owner | test("^[1-9][0-9]*$")) |
          {botToken: $token, ownerId: $owner, model: {provider: $provider, modelId: $model}}
        ' > "$config_file" 2>/dev/null; then
        printf '%s\n' 'Invalid Pi test token or owner configuration.' >&2
        exit 1
      fi
      # Reject the production bot identity even if its token has been rotated.
      if ! production_token=$(${lib.escapeShellArg openclaw} secrets store get TELEGRAM_ALFRED_BOT_TOKEN --plain 2>/dev/null) || [[ -z "$production_token" ]]; then
        printf '%s\n' 'Could not verify that the test bot differs from the OpenClaw bot.' >&2
        exit 1
      fi
      if [[ "$(jq -r '.botToken | split(":")[0]' "$config_file")" == "''${production_token%%:*}" ]]; then
        printf '%s\n' 'Refusing to use the production OpenClaw bot token for Pi tests.' >&2
        exit 1
      fi
      unset production_token

      ${lib.getExe imageBuilder}
      env_args=()
      if [[ -e "$env_file" || -L "$env_file" ]]; then
        if ! private_file "$env_file"; then
          printf '%s\n' 'Pi model environment must be an owned, mode-0600 regular file.' >&2
          exit 1
        fi
        env_args=(--env-file "$env_file")
      elif [[ ${lib.escapeShellArg cfg.provider} == opencode-go ]]; then
        if ! OPENCODE_API_KEY=$(${lib.escapeShellArg openclaw} secrets store get OPENCODE_API_KEY --plain 2>/dev/null) || [[ -z "$OPENCODE_API_KEY" ]]; then
          printf '%s\n' 'Pi requires the existing OpenCode API key or a private model environment file.' >&2
          exit 1
        fi
        export OPENCODE_API_KEY
        env_args=(--env OPENCODE_API_KEY)
      else
        printf '%s\n' 'Add the private model environment file for the selected Pi provider.' >&2
        exit 1
      fi

      podman --connection openclaw-sandbox run --rm --replace --cidfile "$cid_file" \
        --name wave-pi-telegram-test --pull=never \
        --userns=keep-id --read-only --read-only-tmpfs=false \
        --tmpfs /tmp:rw,noexec,nosuid,size=64m,mode=1777 \
        --cap-drop ALL --security-opt no-new-privileges \
        --pids-limit 128 --memory 768m --cpus 1 --stop-timeout 30 \
        "''${env_args[@]}" \
        --env HOME=/tmp --env NODE_ENV=production --env PI_CONFIG_FILE=/run/config.json \
        --mount "type=bind,src=$state_dir,dst=/state" \
        --mount "type=bind,src=$config_file,dst=/run/config.json,readonly" \
        --health-cmd 'node -e "fetch(\"http://127.0.0.1:8080/healthz\").then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"' \
        --health-interval 30s --health-start-period 60s --health-timeout 5s \
        ${lib.escapeShellArg imageBuilder.imageName} &
      container_pid=$!
      stop_container() {
        if [[ -f "$cid_file" ]]; then
          podman --connection openclaw-sandbox stop --time 30 "$(<"$cid_file")" >/dev/null 2>&1 || true
        fi
        wait "$container_pid" || true
        exit 0
      }
      trap stop_container INT TERM
      wait "$container_pid"
    '';
  };
in
{
  options.services.pi-telegram-test = {
    enable = lib.mkEnableOption "one private Telegram bot backed by Pi Durable";
    tokenFile = lib.mkOption {
      type = lib.types.str;
      default = "${config.xdg.configHome}/secrets/pi-telegram-test-token";
    };
    ownerIdFile = lib.mkOption {
      type = lib.types.str;
      default = "${config.xdg.configHome}/secrets/openclaw/telegram-owner-id";
    };
    modelEnvFile = lib.mkOption {
      type = lib.types.str;
      default = "${config.xdg.configHome}/secrets/pi-telegram-test.env";
    };
    provider = lib.mkOption {
      type = lib.types.str;
      default = "opencode-go";
    };
    model = lib.mkOption {
      type = lib.types.str;
      default = "deepseek-v4-flash";
    };
  };
  config = lib.mkIf cfg.enable {
    home.packages = [
      imageBuilder
      runner
    ];
    home.activation.piTelegramTestState = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      ${pkgs.coreutils}/bin/install -d -m 0700 -- "${state}" "${state}/logs"
    '';
    launchd.agents.pi-telegram-test = {
      enable = true;
      domain = "gui";
      config = {
        Label = "org.nix-community.home.pi-telegram-test";
        ProgramArguments = [ (lib.getExe runner) ];
        RunAtLoad = true;
        KeepAlive = {
          SuccessfulExit = false;
        };
        ThrottleInterval = 15;
        ProcessType = "Background";
        Umask = 63;
        StandardOutPath = "${state}/logs/service.log";
        StandardErrorPath = "${state}/logs/service.error.log";
      };
    };
  };
}
