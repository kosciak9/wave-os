{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.alfred;
  slackMirror = config.services.slack-mirror;
  home = config.home.homeDirectory;
  component = "alfred";
  containerName = "wave-alfred";
  logDirectory = "${home}/.local/state/alfred";
  googleState = "${logDirectory}/google-workspace";
  secret = name: "${cfg.secretDirectory}/${name}";
  mcpTokenFile = secret "mcp-token";

  # MCP servers run on the host, where their data and logins are, each behind a loopback
  # Streamable HTTP bridge that only the holder of the generated token may use; every
  # container in the Podman machine can reach the host's loopback. `agent` is the one who
  # may use its tools: Alfred or a subagent.
  # PyMuPDF renders the pages of PDF attachments for the model.
  python = pkgs.workspace-mcp.pythonEnvironment.override (old: {
    extraLibs = old.extraLibs ++ [ pkgs.workspace-mcp.python.pkgs.pymupdf ];
  });
  bridges = {
    obsidian = {
      port = 18091;
      agent = "alfred";
      # In the GUI session, so macOS can ask once for access to the vault's folder.
      domain = "gui";
      command = lib.getExe obsidianMcp;
      tools = [
        "obsidian_list_vaults"
        "obsidian_read_note"
        "obsidian_search_vault"
        "obsidian_create_note"
        "obsidian_edit_note"
        "obsidian_create_directory"
      ];
    };
    google = {
      port = 18092;
      agent = "alfred";
      domain = "user";
      command = lib.getExe googleMcp;
      tools = [
        "search_gmail_messages"
        "get_gmail_message_content"
        "get_gmail_messages_content_batch"
        "get_gmail_thread_content"
        "get_gmail_threads_content_batch"
        "get_gmail_attachment_content"
        "list_gmail_labels"
        "list_calendars"
        "get_events"
        "modify_gmail_message_labels"
        "draft_gmail_message"
        "manage_event"
      ];
    };
    # The Camofox browser (modules/home/camofox); its snapshots stay out of Alfred's thread.
    camofox = {
      port = 18093;
      agent = "browser";
      domain = "user";
      command = lib.getExe camofoxMcp;
      tools = [
        "camofox_create_tab"
        "camofox_snapshot"
        "camofox_navigate"
        "camofox_click"
        "camofox_type"
        "camofox_scroll"
        "camofox_screenshot"
        "camofox_list_tabs"
        "camofox_close_tab"
      ];
    };
    # Reads the publication and edits drafts; never creates, publishes or deletes.
    substack = {
      port = 18094;
      agent = "alfred";
      domain = "user";
      command = lib.getExe substackMcp;
      tools = [
        "get_draft"
        "list_drafts"
        "list_scheduled_posts"
        "preview_draft_body"
        "get_sections"
        "get_publication_settings"
        "list_contributors"
        "get_import_status"
        "list_publication_tags"
        "get_post_tags"
        "list_templates"
        "get_analytics"
        "get_dashboard_summary"
        "get_email_stats"
        "get_growth_sources"
        "get_revenue_summary"
        "get_post_stats"
        "rank_posts"
        "get_subscriber_count"
        "list_posts"
        "search_posts"
        "search_publications"
        "get_publication_info"
        "research_creator_posts"
        "compare_publications"
        "update_draft"
      ];
    };
    languagetool = {
      port = 18095;
      agent = "alfred";
      domain = "user";
      command = lib.getExe languagetoolMcp;
      tools = [ "lt_check_text" ];
    };
  };
  # Reached by the container itself; their credentials go in as Podman secrets.
  remotes = {
    # Twenty CRM; the URL and API key come from the OpenClaw Secret Store.
    twenty.tools = [
      "get_tool_catalog"
      "learn_tools"
      "execute_tool"
      "list_object_metadata_names"
      "list_skills"
      "load_skills"
      "search_help_center"
    ];
    # The read-only Slack mirror (modules/home/slack-mirror) on the host.
    slack.tools = [
      "status"
      "list_conversations"
      "unread"
      "get_conversation"
      "get_thread"
      "search"
      "users"
      "describe_schema"
    ];
  };
  openclawSecret = name: ''
    if ! ${name}=$(${lib.getExe config.programs.openclaw.package} secrets store get ${name} --plain 2>/dev/null) ||
      [[ -z "''$${name}" ]]; then
      printf '%s\n' "could not retrieve ${name} from the OpenClaw Secret Store" >&2
      exit 1
    fi
  '';
  policy =
    agent:
    lib.mapAttrs (_: bridge: bridge.tools) (lib.filterAttrs (_: bridge: bridge.agent == agent) bridges);

  requirePrivateFile = ''
    require_private_file() {
      if [[ -L "$1" || ! -f "$1" ]] ||
        [[ "$(/usr/bin/stat -f %Lp "$1")" != 600 ]] ||
        [[ "$(/usr/bin/stat -f %u "$1")" != "$(/usr/bin/id -u)" ]]; then
        printf '%s\n' "$1 must be a regular file of the user, mode 0600" >&2
        exit 1
      fi
    }
  '';

  obsidianMcp = pkgs.writeShellApplication {
    name = "alfred-obsidian-mcp";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      ${requirePrivateFile}
      vault_path_file=${lib.escapeShellArg (secret "obsidian-vault-path")}
      require_private_file "$vault_path_file"
      vault_path=$(< "$vault_path_file")
      if [[ "$vault_path" != /* || "$vault_path" == *$'\n'* || "$vault_path" == *$'\r'* ]] ||
        [[ ! -d "$vault_path/.obsidian" ]]; then
        printf '%s\n' "$vault_path_file must name a vault with Obsidian metadata" >&2
        exit 1
      fi
      exec env -i HOME="$HOME" PATH="$PATH" \
        ${
          lib.getExe (pkgs.callPackage ../../../packages/obsidian-mcp.nix { })
        } serve --vault "notes=$vault_path"
    '';
  };

  googlePolicy = pkgs.writeText "alfred-google-mcp-policy.json" (
    builtins.toJSON {
      allowedTools = bridges.google.tools;
      # The container cannot read files the server saves on the host.
      inlineAttachments = true;
      gotenbergUrl = "http://127.0.0.1:${toString gotenbergPort}";
    }
  );

  # Gotenberg renders attachments the model cannot read to PDF. It has no way out: an internal
  # network, no downloads or webhooks, and Chromium loads nothing but the file it converts.
  gotenbergPort = 18096;
  gotenberg = pkgs.writeShellApplication {
    name = "alfred-gotenberg";
    runtimeInputs = [
      pkgs.podman
      pkgs.jq
    ];
    text = ''
      transport=(podman --connection ${lib.escapeShellArg cfg.machineName})
      deadline=$((SECONDS + 180))
      until "''${transport[@]}" info --format json 2>/dev/null |
        jq -e '.host.security.rootless == true' >/dev/null 2>&1; do
        if (( SECONDS >= deadline )); then
          printf '%s\n' "${cfg.machineName} rootless connection was not ready within 180 seconds" >&2
          exit 1
        fi
        sleep 2
      done
      "''${transport[@]}" network exists ${containerName}-gotenberg ||
        "''${transport[@]}" network create --internal --label io.wave-os.component=${component} \
          ${containerName}-gotenberg >/dev/null
      "''${transport[@]}" rm --force ${containerName}-gotenberg >/dev/null 2>&1 || true
      exec "''${transport[@]}" run --rm --name ${containerName}-gotenberg \
        --label io.wave-os.component=${component} \
        --pull=missing --network ${containerName}-gotenberg --http-proxy=false \
        --publish 127.0.0.1:${toString gotenbergPort}:3000 \
        --cap-drop ALL --security-opt no-new-privileges --read-only \
        --tmpfs /tmp:rw,nosuid,nodev,size=512m,mode=1777 \
        --tmpfs /home/gotenberg:rw,nosuid,nodev,size=128m,mode=1777 \
        --pids-limit 512 --memory 2g --cpus 2 \
        ${lib.escapeShellArg cfg.gotenbergImage} gotenberg \
        --api-disable-download-from --webhook-disable \
        --chromium-disable-javascript --chromium-deny-public-ips --chromium-deny-private-ips \
        --prometheus-disable-collect --log-level=warn
    '';
  };
  googleMcp = pkgs.writeShellApplication {
    name = "alfred-google-mcp";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
    ];
    text = ''
      umask 077
      ${requirePrivateFile}
      client_file=${lib.escapeShellArg (secret "google-workspace-client.json")}
      email_file=${lib.escapeShellArg (secret "google-workspace-email")}
      state_directory=${lib.escapeShellArg googleState}
      require_private_file "$client_file"
      require_private_file "$email_file"
      if ! jq -e '(.installed // .web) | (.client_id | type == "string" and length > 0) and (.client_secret | type == "string" and length > 0)' "$client_file" >/dev/null 2>&1; then
        printf '%s\n' "$client_file is not a Google OAuth client" >&2
        exit 1
      fi
      email=$(< "$email_file")
      if [[ ! "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
        printf '%s\n' "$email_file does not hold an email address" >&2
        exit 1
      fi
      install -d -m 0700 -- "$state_directory" "$state_directory/credentials" "$state_directory/logs" "$state_directory/attachments"
      cd "$state_directory"
      exec env -i \
        HOME="$state_directory" PATH="$PATH" \
        PYTHONPATH=${lib.escapeShellArg pkgs.workspace-mcp.pythonPath} \
        PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1 \
        GOOGLE_CLIENT_SECRET_PATH="$client_file" USER_GOOGLE_EMAIL="$email" \
        WORKSPACE_MCP_CREDENTIALS_DIR="$state_directory/credentials" \
        WORKSPACE_ATTACHMENT_DIR="$state_directory/attachments" \
        WORKSPACE_MCP_LOG_DIR="$state_directory/logs" WORKSPACE_MCP_LOG_LEVEL=WARNING \
        ${python}/bin/python ${../../../packages/workspace-mcp/launcher.py} ${googlePolicy}
    '';
  };

  # One Camofox session for all of Alfred's browser subagents; each works in tabs of its own.
  camofoxMcp = pkgs.writeShellApplication {
    name = "alfred-camofox-mcp";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      if ! access_key=$(${lib.getExe config.programs.openclaw.package} secrets store get CAMOFOX_ACCESS_KEY --plain 2>/dev/null) ||
        [[ -z "$access_key" ]]; then
        printf '%s\n' "could not retrieve CAMOFOX_ACCESS_KEY from the OpenClaw Secret Store" >&2
        exit 1
      fi
      exec env -i HOME="$HOME" PATH="$PATH" \
        CAMOFOX_BASE_URL=http://127.0.0.1:9377 CAMOFOX_ACCESS_KEY="$access_key" \
        CAMOFOX_USER_ID=alfred \
        ${lib.getExe (pkgs.callPackage ../../../packages/camofox-browser-mcp.nix { })}
    '';
  };

  substackMcp = pkgs.writeShellApplication {
    name = "alfred-substack-mcp";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      ${openclawSecret "SUBSTACK_PUBLICATION_URL"}
      ${openclawSecret "SUBSTACK_SESSION_TOKEN"}
      SUBSTACK_PUBLICATION_URL=$(tr '[:upper:]' '[:lower:]' <<<"$SUBSTACK_PUBLICATION_URL")
      if [[ ! "$SUBSTACK_PUBLICATION_URL" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.substack\.com$ ]]; then
        printf '%s\n' "SUBSTACK_PUBLICATION_URL is not a bare *.substack.com hostname" >&2
        exit 1
      fi
      exec env -i HOME="$HOME" PATH="$PATH" \
        SUBSTACK_PUBLICATION_URL="$SUBSTACK_PUBLICATION_URL" \
        SUBSTACK_SESSION_TOKEN="$SUBSTACK_SESSION_TOKEN" \
        SUBSTACK_READ_ONLY=0 SUBSTACK_ALLOW_DESTRUCTIVE=0 SUBSTACK_MCP_HOME=/dev/null \
        ${lib.getExe pkgs.substack-mcp}
    '';
  };

  # LanguageTool offline, in a container of its own without network.
  languagetoolMcp = pkgs.writeShellApplication {
    name = "alfred-languagetool-mcp";
    runtimeInputs = [ pkgs.podman ];
    text = ''
      ${lib.getExe pkgs.openclaw-languagetool-mcp-image}
      exec podman --connection ${lib.escapeShellArg cfg.machineName} run --rm -i \
        --network none --pull never --read-only \
        --cap-drop ALL --security-opt no-new-privileges --user 65532:65532 \
        --tmpfs /tmp:rw,noexec,nosuid,nodev,size=128m --workdir /tmp \
        --pids-limit 128 --memory 768m --memory-swap 768m --cpus 1 \
        --http-proxy=false --log-driver none \
        --label io.wave-os.component=${component}-languagetool \
        ${lib.escapeShellArg pkgs.openclaw-languagetool-mcp-image.imageName}
    '';
  };

  bridgeAgent = name: bridge: {
    enable = true;
    inherit (bridge) domain;
    config = {
      ProgramArguments = [
        "${python}/bin/python"
        "${./mcp-bridge.py}"
        name
        (toString bridge.port)
        mcpTokenFile
        bridge.command
      ];
      RunAtLoad = true;
      KeepAlive = true;
      ProcessType = "Background";
      ThrottleInterval = 30;
      Umask = 63;
      StandardOutPath = "/dev/null";
      StandardErrorPath = "${logDirectory}/mcp-${name}.error.log";
    };
  };

  browser = {
    description = "Szuka i czyta w sieci, a w przeglądarce Camofox także klika i wypełnia formularze, również na stronach dynamicznych i chronionych przed botami.";
    prompt = ''
      Jesteś przeglądarką Alfreda. Dostajesz jedno zadanie w sieci i wykonujesz je dwiema
      przeglądarkami.

      Lightpanda jest szybka i tania, ale tylko czyta: search zwraca wyniki wyszukiwania, goto
      otwiera stronę, markdown podaje jej treść (także renderowaną przez JavaScript), links jej
      odnośniki. Zaczynaj od niej, gdy trzeba coś znaleźć albo przeczytać.

      Camofox to Firefox odporny na wykrywanie botów: użyj go, gdy trzeba klikać lub pisać, albo
      gdy Lightpanda zostaje zablokowana czy nie widzi treści. Otwórz kartę przez
      camofox_create_tab, a stronę czytaj przez camofox_snapshot; jego odnośniki (e1, e2, …)
      wskazują elementy dla camofox_click i camofox_type. Po każdej akcji zrób snapshot ponownie.

      Nie wpisuj haseł ani kodów i niczego nie kupuj, nie wysyłaj ani nie publikuj, jeśli zadanie
      wprost tego nie każe. Gdy strona wymaga logowania, przerwij i zgłoś to z adresem strony.

      Na koniec zamknij swoje karty w Camofoksie i odpowiedz zwięźle: ustalenia z adresami źródeł, oddziel
      fakty od wniosków i powiedz, czego nie udało się sprawdzić.
    '';
  };

  # Read by house-agents in the container; the secrets come from Podman secrets and the env file.
  agentConfig = pkgs.writeText "house-agents.config.ts" ''
    import { readFileSync } from "node:fs";

    const bridge = (port: number) => ({
    	url: `http://host.containers.internal:''${port}/mcp`,
    	headers: { Authorization: `Bearer ''${process.env.ALFRED_MCP_TOKEN}` },
    });

    export default {
    	prompt: readFileSync("/run/secrets/prompt.md", "utf8"),
    	model: { provider: "openai-codex", modelId: "gpt-6.1-sol", thinkingLevel: "medium" },
    	fallbackModel: { provider: "xai", modelId: "grok-4.7", thinkingLevel: "medium" },
    	telegram: { chatId: Number(process.env.TELEGRAM_CHAT_ID) },
    	// whisper-recording-proxy on the host.
    	whisperUrl: "http://host.containers.internal:18080/v1/audio/transcriptions",
    	gotenbergUrl: "http://host.containers.internal:${toString gotenbergPort}",
    	mcpServers: {
    ${lib.concatMapAttrsStringSep "\n" (
      name: bridge: "		${name}: bridge(${toString bridge.port}),"
    ) bridges}
    		twenty: {
    			url: process.env.TWENTY_MCP_URL,
    			headers: { Authorization: `Bearer ''${process.env.TWENTY_API_KEY}` },
    		},
    		slack: {
    			url: "http://host.containers.internal:${toString slackMirror.port}/mcp",
    			headers: { Authorization: `Bearer ''${process.env.SLACK_MIRROR_MCP_TOKEN}` },
    		},
    	},
    	mcp: ${builtins.toJSON (policy "alfred" // lib.mapAttrs (_: remote: remote.tools) remotes)},
    	subagents: {
    		browser: {
    			description: ${builtins.toJSON browser.description},
    			prompt: ${builtins.toJSON browser.prompt},
    			mcp: ${builtins.toJSON (policy "browser")},
    			// Lightpanda from the image, a fresh one for each run; only reading: Camofox interacts.
    			lightpanda: true,
    		},
    	},
    	stateDir: "/data/state",
    };
  '';

  supervisor = pkgs.writeShellApplication {
    name = "alfred-supervisor";
    runtimeInputs = [
      pkgs.podman
      pkgs.jq
      pkgs.coreutils
      pkgs.curl
    ];
    text = ''
      machine=${lib.escapeShellArg cfg.machineName}
      env_file=${lib.escapeShellArg (secret "env")}
      prompt_file=${lib.escapeShellArg (secret "prompt.md")}
      token_file=${lib.escapeShellArg mcpTokenFile}
      slack_token_file=${lib.escapeShellArg "${slackMirror.secretDirectory}/mcp-token"}
      volume=${lib.escapeShellArg cfg.dataVolume}
      image=${lib.escapeShellArg cfg.image}

      ${requirePrivateFile}
      require_private_file "$env_file"
      require_private_file "$prompt_file"
      require_private_file "$token_file"
      require_private_file "$slack_token_file"
      if ! grep -q '^TELEGRAM_BOT_TOKEN=.' "$env_file" ||
        ! grep -q '^TELEGRAM_CHAT_ID=-\?[0-9]\+$' "$env_file"; then
        printf '%s\n' "$env_file must set TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID" >&2
        exit 1
      fi

      if ! state=$(podman machine inspect "$machine" | jq -er '
        if length == 1 and .[0].Rootful == false then .[0].State else error("rootful machine") end'); then
        printf '%s\n' "Provision a rootless $machine machine before starting Alfred" >&2
        exit 1
      fi
      if [[ "$state" == stopped ]]; then
        if ! podman machine start --update-connection=false "$machine"; then
          printf '%s\n' "Could not start $machine; Podman permits only one active managed VM." >&2
          exit 1
        fi
      fi
      transport=(podman --connection "$machine")
      deadline=$((SECONDS + 180))
      until "''${transport[@]}" info --format json 2>/dev/null |
        jq -e '.host.security.rootless == true' >/dev/null 2>&1; do
        if (( SECONDS >= deadline )); then
          printf '%s\n' "$machine rootless connection was not ready within 180 seconds" >&2
          exit 1
        fi
        sleep 2
      done
      # The agent leaves out an MCP server it cannot reach at start.
      for port in ${
        lib.concatMapAttrsStringSep " " (_: bridge: toString bridge.port) bridges
      } ${toString slackMirror.port}; do
        until [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$port/mcp")" != 000 ]]; do
          if (( SECONDS >= deadline )); then
            printf '%s\n' "the MCP bridge on port $port was not ready" >&2
            exit 1
          fi
          sleep 2
        done
      done

      if "''${transport[@]}" container exists ${containerName}; then
        stale_id=$("''${transport[@]}" container inspect ${containerName} |
          jq -er '.[0] | if .Config.Labels["io.wave-os.component"] == "${component}"
            then .Id else error("container is not owned by Alfred") end')
        "''${transport[@]}" rm --force "$stale_id" >/dev/null
      fi
      # The conversation, memory, schedules and logins: keep and back up.
      if "''${transport[@]}" volume exists "$volume"; then
        "''${transport[@]}" volume inspect "$volume" |
          jq -e '.[0].Labels["io.wave-os.component"] == "${component}"' >/dev/null
      else
        "''${transport[@]}" volume create --label io.wave-os.component=${component} "$volume" >/dev/null
      fi
      put_secret() {
        if "''${transport[@]}" secret exists "$1"; then
          "''${transport[@]}" secret inspect "$1" |
            jq -e '.[0].Spec.Labels["io.wave-os.component"] == "${component}"' >/dev/null
        fi
        "''${transport[@]}" secret create --replace --label io.wave-os.component=${component} "$1" "$2" >/dev/null
      }
      put_secret wave-alfred-config ${agentConfig}
      put_secret wave-alfred-prompt "$prompt_file"
      put_secret wave-alfred-mcp-token "$token_file"
      ${openclawSecret "TWENTY_MCP_URL"}
      ${openclawSecret "TWENTY_API_KEY"}
      printf '%s' "$TWENTY_MCP_URL" | put_secret wave-alfred-twenty-url -
      printf '%s' "$TWENTY_API_KEY" | put_secret wave-alfred-twenty-key -
      unset TWENTY_MCP_URL TWENTY_API_KEY
      printf '%s' "$(< "$slack_token_file")" | put_secret wave-alfred-slack-token -

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
        --volume "$volume:/data/state:rw,Z" \
        --secret source=wave-alfred-config,type=mount,target=/data/house-agents.config.ts,uid=1000,gid=1000,mode=0400 \
        --secret source=wave-alfred-prompt,type=mount,target=prompt.md,uid=1000,gid=1000,mode=0400 \
        --secret source=wave-alfred-mcp-token,type=env,target=ALFRED_MCP_TOKEN \
        --secret source=wave-alfred-twenty-url,type=env,target=TWENTY_MCP_URL \
        --secret source=wave-alfred-twenty-key,type=env,target=TWENTY_API_KEY \
        --secret source=wave-alfred-slack-token,type=env,target=SLACK_MIRROR_MCP_TOKEN \
        "$image" &
      child=$!
      wait "$child"
    '';
  };
in
{
  options.services.alfred = {
    enable = lib.mkEnableOption "Alfred, the house-agents assistant on Telegram";
    image = lib.mkOption {
      type = lib.types.strMatching "[^@]+@sha256:[0-9a-f]{64}";
      # house-agents 702af54 (linux/amd64, linux/arm64)
      default = "ghcr.io/kosciak9/house-agents@sha256:a4645fdd2d1fe6f8df7ed29b5e2628080052a84c975daf4c94a926788d2e0e59";
      description = "The house-agents image, pinned by digest.";
    };
    gotenbergImage = lib.mkOption {
      type = lib.types.strMatching "[^@]+@sha256:[0-9a-f]{64}";
      default = "docker.io/gotenberg/gotenberg:8.37.0@sha256:f29984bd1e226bf1b93ba90af06000afa8b315853e99d27b9aaa41b93f15c769";
      description = "The Gotenberg image that renders attachments to PDF, pinned by digest.";
    };
    secretDirectory = lib.mkOption {
      type = lib.types.str;
      default = "${home}/.config/secrets/alfred";
      description = ''
        Private directory (0700) of 0600 files: `env` (TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID),
        `prompt.md` (who Alfred is), `obsidian-vault-path`, `google-workspace-client.json` and
        `google-workspace-email`; `mcp-token` is generated. Restart after replacing one.
      '';
    };
    machineName = lib.mkOption {
      type = lib.types.strMatching "[a-zA-Z0-9][a-zA-Z0-9_-]*";
      default = "wave-services";
      description = "Pre-provisioned rootless Podman machine and connection.";
    };
    dataVolume = lib.mkOption {
      type = lib.types.strMatching "[a-zA-Z0-9][a-zA-Z0-9_.-]*";
      default = "wave-alfred-state";
      description = "Persistent named volume for the agent's state; retained across restarts and upgrades.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.isDarwin;
        message = "Alfred launchd supervision requires Darwin.";
      }
      {
        assertion = slackMirror.enable;
        message = "Alfred reads Slack through services.slack-mirror.";
      }
      {
        assertion = lib.hasPrefix "/" cfg.secretDirectory;
        message = "Alfred secretDirectory must be absolute.";
      }
    ];
    home.activation.alfred = lib.hm.dag.entryBetween [ "setupLaunchAgents" ] [ "writeBoundary" ] ''
      run install -d -m 0700 ${lib.escapeShellArg logDirectory} ${lib.escapeShellArg cfg.secretDirectory}
      if [[ ! -e ${lib.escapeShellArg mcpTokenFile} ]]; then
        run sh -c 'umask 077 && od -An -N32 -tx1 /dev/urandom | tr -d " \n" > "$1"' _ ${lib.escapeShellArg mcpTokenFile}
      fi
    '';
    launchd.agents = {
      alfred = {
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
      alfred-gotenberg = {
        enable = true;
        domain = "user";
        config = {
          ProgramArguments = [ (lib.getExe gotenberg) ];
          RunAtLoad = true;
          KeepAlive = true;
          ProcessType = "Background";
          ThrottleInterval = 30;
          Umask = 63;
          StandardOutPath = "/dev/null";
          StandardErrorPath = "${logDirectory}/gotenberg.error.log";
        };
      };
    }
    // lib.mapAttrs' (
      name: bridge: lib.nameValuePair "alfred-mcp-${name}" (bridgeAgent name bridge)
    ) bridges;
  };
}
