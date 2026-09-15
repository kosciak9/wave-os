{
  config,
  lib,
  pkgs,
  ...
}:

let
  home = config.home.homeDirectory;
  state = "${home}/.openclaw";
  workspace = "${state}/workspace";
  telegramGroupIdFile = "${home}/.config/secrets/openclaw/telegram-group-id";
  telegramGroupAllowFromFile = "${home}/.config/secrets/openclaw/telegram-group-allow-from.json";
  runtimeConfigDirectory = "${state}/runtime-config";
  runtimeConfig = "${runtimeConfigDirectory}/openclaw.json";
  # MCP deny patterns are either exact tool names or prefix patterns ending in '*'.
  toolMatches =
    pattern: tool:
    if lib.hasSuffix "*" pattern then
      lib.hasPrefix (lib.removeSuffix "*" pattern) tool
    else
      pattern == tool;
  listsAreDisjoint =
    allowed: denied:
    builtins.all (tool: builtins.all (pattern: !(toolMatches pattern tool)) denied) allowed;
  listIsDuplicateFree = list: builtins.length list == builtins.length (lib.unique list);
  secret = id: {
    source = "store";
    provider = "default";
    inherit id;
  };
  approvedTools = [
    "read"
    "write"
    "edit"
    "apply_patch"
    "exec"
    "process"
    "web_search"
    "web_fetch"
    "memory_search"
    "memory_get"
    "sessions_list"
    "sessions_history"
    "sessions_search"
    "sessions_spawn"
    "sessions_yield"
    "subagents"
    "automations"
    "ask_user"
    "progress_card"
    "screen"
    "dashboard"
    "show_widget"
    "view_image"
    "pdf"
    "image_generate"
    "message"
  ];
  sandboxTools = [ "session_status" ] ++ approvedTools;
  camofoxTools = [
    "camofox_create_tab"
    "camofox_snapshot"
    "camofox_click"
    "camofox_type"
    "camofox_navigate"
    "camofox_scroll"
    "camofox_screenshot"
    "camofox_close_tab"
    "camofox_list_tabs"
  ];
  macAppsMcpReadTools = [
    "mail_list_accounts"
    "mail_list_mailboxes"
    "mail_get_emails"
    "mail_get_email"
    "mail_search"
    "mail_search_body"
    "mail_fts_index"
    "mail_fts_stats"
    "calendar_list"
    "calendar_today"
    "calendar_this_week"
    "calendar_get_events"
    "calendar_get_event"
  ];
  macAppsMcpAutonomousWriteTools = [
    "mail_set_flags"
    "mail_move"
    "mail_create_draft"
    "calendar_create_event"
    "calendar_modify_event"
  ];
  macAppsMcpDeniedTools = [
    "mail_send"
    "mail_reply"
    "mail_forward"
    "calendar_delete_event"
    "reminders_*"
    "notes_*"
  ];
  macAppsMcpTools = macAppsMcpReadTools ++ macAppsMcpAutonomousWriteTools;
  macAppsMcpPolicyIds = map (tool: "mac-apps__${tool}") macAppsMcpTools;
  obsidianMcpReadTools = [
    "vault_list"
    "vault_read"
    "vault_get_document_map"
    "active_file_get_path"
    "search_query"
    "search_simple"
    "tag_list"
    "command_list"
  ];
  obsidianMcpAutonomousWriteTools = [
    "vault_write"
    "vault_append"
    "vault_patch"
    "vault_move"
    "vault_copy"
  ];
  obsidianMcpDeniedTools = [
    "vault_delete"
    "command_execute"
    "open_file"
  ];
  obsidianMcpTools = obsidianMcpReadTools ++ obsidianMcpAutonomousWriteTools;
  obsidianMcpPolicyIds = map (tool: "obsidian__${tool}") obsidianMcpTools;
  anytypeMcpReadTools = [
    "API-search-global"
    "API-list-spaces"
    "API-get-space"
    "API-get-list-views"
    "API-get-list-objects"
    "API-list-members"
    "API-get-member"
    "API-list-objects"
    "API-get-object"
    "API-list-properties"
    "API-get-property"
    "API-list-tags"
    "API-get-tag"
    "API-search-space"
    "API-list-types"
    "API-get-type"
    "API-list-templates"
    "API-get-template"
  ];
  anytypeMcpAutonomousWriteTools = [
    "API-create-object"
    "API-update-object"
  ];
  anytypeMcpDeniedTools = [
    "API-delete-object"
    "API-create-space"
    "API-update-space"
    "API-add-list-objects"
    "API-remove-list-object"
    "API-create-property"
    "API-delete-property"
    "API-update-property"
    "API-create-tag"
    "API-delete-tag"
    "API-update-tag"
    "API-create-type"
    "API-delete-type"
    "API-update-type"
  ];
  anytypeMcpTools = anytypeMcpReadTools ++ anytypeMcpAutonomousWriteTools;
  anytypeMcpPolicyIds = map (tool: "anytype__${tool}") anytypeMcpTools;
  substackMcpEditorialReadTools = [
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
  ];
  substackMcpAnalyticsReadTools = [
    "get_analytics"
    "get_dashboard_summary"
    "get_email_stats"
    "get_growth_sources"
    "get_revenue_summary"
    "get_post_stats"
    "rank_posts"
    "get_subscriber_count"
  ];
  substackMcpPublicReadTools = [
    "list_posts"
    "search_posts"
    "search_publications"
    "get_publication_info"
    "research_creator_posts"
    "compare_publications"
  ];
  substackMcpAutonomousWriteTools = [
    "update_draft"
  ];
  substackMcpDeniedTools = [
    "create_draft"
    "delete_draft"
    "publish_draft"
    "schedule_draft"
    "unschedule_draft"
    "set_draft_body"
    "publish_note"
    "publish_note_with_link"
    "schedule_note"
    "cancel_scheduled_note"
    "delete_note"
    "add_subscriber"
    "create_tag"
    "add_tag_to_post"
    "remove_tag_from_post"
    "comment_on_post"
    "delete_comment"
    "restack_note"
    "update_publication_settings"
    "create_template"
    "delete_template"
    "create_draft_from_template"
    "upload_image"
    "list_subscribers"
    "export_subscribers"
    "list_subscriptions"
    "list_reader_posts"
    "get_reader_post"
    "get_reader_feed"
    "get_profile_feed"
    "get_user_profile"
    "get_post_comments"
    "get_comment_thread"
    "get_post"
    "get_post_by_id"
    "research_creator_notes"
    "scrape_post"
    "list_notes"
    "list_scheduled_notes"
  ];
  substackMcpAllowedTools =
    substackMcpEditorialReadTools
    ++ substackMcpAnalyticsReadTools
    ++ substackMcpPublicReadTools
    ++ substackMcpAutonomousWriteTools;
  substackMcpPolicyIds = map (tool: "substack__${tool}") substackMcpAllowedTools;
  languagetoolMcpTools = [ "lt_check_text" ];
  languagetoolMcpPolicyIds = map (tool: "languagetool__${tool}") languagetoolMcpTools;
  homeAssistantMcpReadTools = [
    "ha_get_app"
    "ha_list_floors_areas"
    "ha_get_blueprint"
    "ha_get_camera_image"
    "ha_config_get_category"
    "ha_config_get_automation"
    "ha_config_get_dashboard"
    "ha_config_list_helpers"
    "ha_config_get_scene"
    "ha_config_get_script"
    "ha_get_entity"
    "ha_config_list_groups"
    "ha_get_hacs_info"
    "ha_get_history"
    "ha_get_integration"
    "ha_config_get_label"
    "ha_get_logs"
    "ha_get_device"
    "ha_config_list_dashboard_resources"
    "ha_get_overview"
    "ha_get_state"
    "ha_search"
    "ha_get_operation_status"
    "ha_list_services"
    "ha_get_system_health"
    "ha_get_automation_traces"
    "ha_eval_template"
    "ha_get_entity_exposure"
    "ha_get_zone"
    "ha_get_skill_guide"
  ];
  homeAssistantMcpControlTools = [
    "ha_bulk_control"
    "ha_call_service"
  ];
  homeAssistantMcpAdminTools = [
    "ha_manage_hacs"
    "ha_restart"
    "ha_manage_updates"
    "ha_manage_backup"
  ];
  homeAssistantMcpTools =
    homeAssistantMcpReadTools ++ homeAssistantMcpControlTools ++ homeAssistantMcpAdminTools;
  homeAssistantMcpDeniedTools = [
    "ha_manage_app"
    "ha_remove_area_or_floor"
    "ha_set_area_or_floor"
    "ha_manage_pipeline"
    "ha_import_blueprint"
    "ha_report_issue"
    "ha_config_get_calendar_events"
    "ha_config_remove_calendar_event"
    "ha_config_set_calendar_event"
    "ha_config_remove_category"
    "ha_config_set_category"
    "ha_config_remove_automation"
    "ha_config_set_automation"
    "ha_config_delete_dashboard"
    "ha_config_set_dashboard"
    "ha_config_set_helper"
    "ha_config_remove_scene"
    "ha_config_set_scene"
    "ha_config_remove_script"
    "ha_config_set_script"
    "ha_manage_energy_prefs"
    "ha_remove_entity"
    "ha_set_entity"
    "ha_config_remove_group"
    "ha_config_set_group"
    "ha_remove_helpers_integrations"
    "ha_set_integration"
    "ha_config_remove_label"
    "ha_config_set_label"
    "ha_manage_radio"
    "ha_remove_device"
    "ha_set_device"
    "ha_config_delete_dashboard_resource"
    "ha_config_set_dashboard_resource"
    "ha_call_event"
    "ha_reload_core"
    "ha_manage_theme"
    "ha_get_todo"
    "ha_remove_todo_item"
    "ha_set_todo_item"
    "ha_remove_zone"
    "ha_set_zone"
  ];
  homeAssistantMcpPolicyIds = map (tool: "home-assistant__${tool}") homeAssistantMcpTools;
  macAppsMcpHostApp = "${home}/Applications/Home Manager Apps/Mac Apps MCP Host.app";
  deniedTools = [
    "sessions_send"
    "conversations_send"
    "code_execution"
    "browser"
    "terminal"
    "portal"
    "canvas"
    "nodes"
    "computer"
    "gateway"
    "skill_workshop"
    "publishing"
    "tts"
    "music"
    "video"
    "music_generate"
    "video_generate"
    "image_generation"
    "file_transfer"
    "codex"
    "cua-computer"
    "camofox_evaluate"
    "camofox_import_cookies"
    "xai"
  ];
  enabledPluginIds = [
    "openai"
    "telegram"
    "memory-core"
    "active-memory"
    "llama-cpp"
    "camofox-browser"
    "document-extract"
    "web-readability"
    "device-pair"
  ];
  # Exhaustive complement for pinned OpenClaw 2026.9.3: default-on bundled plugins stay disabled visibly and at runtime.
  disabledPluginIds = [
    "a2a"
    "acpx"
    "admin-http-rpc"
    "alibaba"
    "anthropic"
    "azure-speech"
    "beam"
    "bonjour"
    "browser"
    "canvas"
    "clawrouter"
    "copilot-proxy"
    "crabbox"
    "cua-computer"
    "deepgram"
    "elevenlabs"
    "fal"
    "file-transfer"
    "geolocation"
    "github-copilot"
    "google"
    "huggingface"
    "imap"
    "linux-node"
    "litellm"
    "llm-task"
    "lmstudio"
    "logbook"
    "memory-wiki"
    "microsoft"
    "microsoft-foundry"
    "migrate-claude"
    "migrate-hermes"
    "minimax"
    "nvidia"
    "oc-path"
    "ollama"
    "onepassword"
    "opencode-go"
    "openrouter"
    "policy"
    "reef"
    "runway"
    "senseaudio"
    "sglang"
    "talk-voice"
    "together"
    "tts-local-cli"
    "vault"
    "vllm"
    "webhooks"
    "workboard"
    "xai"
  ];
  openclawPackageSetBase = pkgs.openclawPackages.withTools { excludeToolNames = [ "git" ]; };
  # Pinned OpenClaw 2026.9.3 registers both the built-in session dashboard and Telegram Mini App as /dashboard; preserve the built-in command and rename the Mini App command to /openclaw_ui until upstream resolves it.
  patchedOpenclawGateway = openclawPackageSetBase.openclaw-gateway.overrideAttrs (oldAttrs: {
    installPhase = ''
      ${oldAttrs.installPhase}
      miniappChunk="$out/lib/openclaw/dist/miniapp-api-Cf_7TwyD.mjs"
      if [ ! -f "$miniappChunk" ]; then
        printf '%s\n' "refusing to build OpenClaw Gateway: expected Telegram Mini App bundle is missing: $miniappChunk" >&2
        exit 1
      fi
      substituteInPlace "$miniappChunk" \
        --replace-fail 'name: "dashboard",' 'name: "openclaw_ui",'
    '';
  });
  openclawPackageSet = openclawPackageSetBase // {
    openclaw = openclawPackageSetBase.openclaw.override {
      openclaw-gateway = patchedOpenclawGateway;
    };
  };
  openclawApp = pkgs.openclawPackages.openclaw-app;
  openclawPackage = openclawPackageSet.openclaw.override {
    openclaw-app = openclawApp;
  };
  install = lib.getExe' pkgs.coreutils "install";
  openclaw = lib.getExe openclawPackage;
  openclawCliWrapper = pkgs.writeShellScriptBin "openclaw" ''
    set -euo pipefail

    if [[ -z "''${OPENCLAW_GATEWAY_TOKEN:-}" ]]; then
      if token=$(
        ${lib.escapeShellArg openclaw} secrets store get OPENCLAW_GATEWAY_TOKEN --plain 2>/dev/null
      ) && [[ -n "$token" ]]; then
        export OPENCLAW_GATEWAY_TOKEN="$token"
      fi
    fi

    if [[ -z "''${OBSIDIAN_LOCAL_REST_API_KEY:-}" ]]; then
      if obsidian_token=$(
        ${lib.escapeShellArg openclaw} secrets store get OBSIDIAN_LOCAL_REST_API_KEY --plain 2>/dev/null
      ) && [[ -n "$obsidian_token" ]]; then
        export OBSIDIAN_LOCAL_REST_API_KEY="$obsidian_token"
      fi
    fi

    exec ${lib.escapeShellArg openclaw} "$@"
  '';
  podman = lib.getExe pkgs.podman;
  jq = lib.getExe pkgs.jq;
  anytypeMcp = pkgs.writeShellApplication {
    name = "openclaw-anytype-mcp";
    runtimeInputs = [
      pkgs.jq
      openclawPackage
      pkgs.anytype-mcp
    ];
    text = ''
      set -euo pipefail

      openclaw=${lib.escapeShellArg openclaw}
      jq=${lib.escapeShellArg jq}

      if ! key=$(
        "$openclaw" secrets store get ANYTYPE_API_KEY --plain 2>/dev/null
      ); then
        printf '%s\n' "refusing to start Anytype MCP: could not retrieve ANYTYPE_API_KEY from the OpenClaw store" >&2
        exit 1
      fi
      if [ -z "$key" ]; then
        printf '%s\n' "refusing to start Anytype MCP: ANYTYPE_API_KEY is empty" >&2
        exit 1
      fi

      # shellcheck disable=SC2016
      OPENAPI_MCP_HEADERS=$("$jq" -cn --arg key "$key" \
        '{Authorization: ("Bearer " + $key), "Anytype-Version": "2025-11-08"}')
      export OPENAPI_MCP_HEADERS
      export ANYTYPE_API_BASE_URL=http://127.0.0.1:31012
      exec ${lib.getExe pkgs.anytype-mcp} "$@"
    '';
  };
  substackMcp = pkgs.writeShellApplication {
    name = "openclaw-substack-mcp";
    runtimeInputs = [
      openclawPackage
      pkgs.substack-mcp
      pkgs.coreutils
    ];
    text = ''
      set -euo pipefail

      openclaw=${lib.escapeShellArg openclaw}
      if ! publication_url=$(
        "$openclaw" secrets store get SUBSTACK_PUBLICATION_URL --plain 2>/dev/null
      ); then
        printf '%s\n' "refusing to start Substack MCP: could not retrieve SUBSTACK_PUBLICATION_URL from the OpenClaw store" >&2
        exit 1
      fi
      if ! session_token=$(
        "$openclaw" secrets store get SUBSTACK_SESSION_TOKEN --plain 2>/dev/null
      ); then
        printf '%s\n' "refusing to start Substack MCP: could not retrieve SUBSTACK_SESSION_TOKEN from the OpenClaw store" >&2
        exit 1
      fi
      if [ -z "$publication_url" ] || [ -z "$session_token" ]; then
        printf '%s\n' "refusing to start Substack MCP: required OpenClaw store value is empty" >&2
        exit 1
      fi

      publication_url=$(${pkgs.coreutils}/bin/tr '[:upper:]' '[:lower:]' <<<"$publication_url")
      if [[ ! "$publication_url" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.substack\.com$ ]]; then
        printf '%s\n' "refusing to start Substack MCP: stored publication URL is not a bare canonical *.substack.com hostname" >&2
        exit 1
      fi
      unset OPENCLAW_GATEWAY_TOKEN CAMOFOX_ACCESS_KEY OBSIDIAN_LOCAL_REST_API_KEY ANYTYPE_API_KEY OPENAPI_MCP_HEADERS
      export SUBSTACK_PUBLICATION_URL="$publication_url"
      export SUBSTACK_SESSION_TOKEN="$session_token"
      export SUBSTACK_READ_ONLY=0
      export SUBSTACK_ALLOW_DESTRUCTIVE=0
      export SUBSTACK_MCP_HOME=/dev/null
      unset publication_url session_token
      exec ${lib.getExe pkgs.substack-mcp} "$@"
    '';
  };
  languagetoolMcp = pkgs.writeShellApplication {
    name = "openclaw-languagetool-mcp";
    runtimeInputs = [
      pkgs.openclaw-languagetool-mcp-image
      pkgs.podman
    ];
    text = ''
      set -euo pipefail

      ${lib.getExe pkgs.openclaw-languagetool-mcp-image}
      exec ${podman} --connection openclaw-sandbox run --rm -i \
        --network none \
        --pull never \
        --read-only \
        --cap-drop ALL \
        --security-opt no-new-privileges \
        --user 65532:65532 \
        --tmpfs /tmp:rw,noexec,nosuid,nodev,size=128m \
        --workdir /tmp \
        --pids-limit 128 \
        --memory 768m \
        --memory-swap 768m \
        --cpus 1 \
        --http-proxy=false \
        --log-driver none \
        --label io.wave-os.openclaw-mcp=languagetool \
        ${lib.escapeShellArg pkgs.openclaw-languagetool-mcp-image.imageName}
    '';
  };
  gatewayWrapper = pkgs.writeShellScript "openclaw-gateway-wrapper" ''
    #!/bin/sh
    set -eu

    while [ ! -d /nix/store ]; do
      /bin/sleep 1
    done

    openclaw=${lib.escapeShellArg openclaw}
    podman=${lib.escapeShellArg podman}
    jq=${lib.escapeShellArg jq}
    install=${lib.escapeShellArg install}
    mktemp=${lib.escapeShellArg (lib.getExe' pkgs.coreutils "mktemp")}
    chmod=${lib.escapeShellArg (lib.getExe' pkgs.coreutils "chmod")}
    mv=${lib.escapeShellArg (lib.getExe' pkgs.coreutils "mv")}
    rm=${lib.escapeShellArg (lib.getExe' pkgs.coreutils "rm")}
    machine_checker=${lib.escapeShellArg (lib.getExe pkgs.openclaw-sandbox-machine-check)}
    runtime_config_directory=${lib.escapeShellArg runtimeConfigDirectory}
    runtime_config=${lib.escapeShellArg runtimeConfig}
    telegram_group_id_file=${lib.escapeShellArg telegramGroupIdFile}
    telegram_group_allow_from_file=${lib.escapeShellArg telegramGroupAllowFromFile}
    tmp_config=
    cleanup() {
      if [ -n "$tmp_config" ]; then
        "$rm" -f -- "$tmp_config" 2>/dev/null || true
      fi
    }
    trap cleanup 0
    trap 'cleanup; exit 1' HUP INT TERM

    if [ -z "''${OPENCLAW_CONFIG_GENERATION:-}" ] || \
      [ ! -f "$OPENCLAW_CONFIG_GENERATION" ] || [ ! -r "$OPENCLAW_CONFIG_GENERATION" ]; then
      printf '%s\n' "refusing to start OpenClaw Gateway: generated config prerequisite is invalid" >&2
      exit 1
    fi
    if [ -L "$telegram_group_id_file" ] || [ ! -f "$telegram_group_id_file" ] || \
      [ ! -r "$telegram_group_id_file" ] || \
      [ "$(/usr/bin/stat -f %Lp "$telegram_group_id_file" 2>/dev/null)" != 600 ]; then
      printf '%s\n' "refusing to start OpenClaw Gateway: private Telegram group configuration is invalid" >&2
      exit 1
    fi
    if ! telegram_group_id=$(
      "$jq" -R -s -e -r '
        (if endswith("\n") then .[:-1] else . end) |
        select(test("^-[1-9][0-9]+$") and (test("[\r\n]") | not))
      ' "$telegram_group_id_file" 2>/dev/null
    ); then
      printf '%s\n' "refusing to start OpenClaw Gateway: private Telegram group configuration is invalid" >&2
      exit 1
    fi
    if [ -L "$telegram_group_allow_from_file" ] || [ ! -f "$telegram_group_allow_from_file" ] || \
      [ ! -r "$telegram_group_allow_from_file" ] || \
      [ "$(/usr/bin/stat -f %Lp "$telegram_group_allow_from_file" 2>/dev/null)" != 600 ]; then
      printf '%s\n' "refusing to start OpenClaw Gateway: private Telegram group configuration is invalid" >&2
      exit 1
    fi
    if ! telegram_group_allow_from=$(
      "$jq" -c -e -s '
        if length != 1 then empty else .[0] end |
        select(
          type == "array" and
          length == 2 and
          all(.[]; type == "string" and test("^[1-9][0-9]+$")) and
          length == (unique | length)
        )
      ' "$telegram_group_allow_from_file" 2>/dev/null
    ); then
      printf '%s\n' "refusing to start OpenClaw Gateway: private Telegram group configuration is invalid" >&2
      exit 1
    fi
    if [ -L "$runtime_config_directory" ] || \
      { [ -e "$runtime_config_directory" ] && [ ! -d "$runtime_config_directory" ]; }; then
      printf '%s\n' "refusing to start OpenClaw Gateway: runtime config directory is invalid" >&2
      exit 1
    fi
    if ! "$install" -d -m 700 -- "$runtime_config_directory" 2>/dev/null || \
      [ "$(/usr/bin/stat -f %Lp "$runtime_config_directory" 2>/dev/null)" != 700 ]; then
      printf '%s\n' "refusing to start OpenClaw Gateway: runtime config directory is invalid" >&2
      exit 1
    fi
    umask 077
    if ! tmp_config=$("$mktemp" "$runtime_config_directory/.openclaw.json.XXXXXX" 2>/dev/null); then
      printf '%s\n' "refusing to start OpenClaw Gateway: could not create runtime config" >&2
      exit 1
    fi
    if ! token=$(
      "$openclaw" secrets store get OPENCLAW_GATEWAY_TOKEN --plain 2>/dev/null
    ); then
      printf '%s\n' "refusing to start OpenClaw Gateway: could not retrieve OPENCLAW_GATEWAY_TOKEN from the store" >&2
      exit 1
    fi
    if [ -z "$token" ]; then
      printf '%s\n' "refusing to start OpenClaw Gateway: OPENCLAW_GATEWAY_TOKEN is empty" >&2
      exit 1
    fi

    export OPENCLAW_GATEWAY_TOKEN="$token"

    metadata=$("$openclaw" secrets store list --json)
    if ! home_assistant_metadata_status=$(printf '%s' "$metadata" | "$jq" -r '
      [ .[]? | select(.name == "HOME_ASSISTANT_MCP_URL") ] as $entries |
      if ($entries | length) == 1
        and $entries[0].kind == "env"
        and (($entries[0].allowedHosts // []) == []) then "valid"
      else "invalid"
      end
    '); then
      unset metadata home_assistant_metadata_status
      printf '%s\n' "refusing to start OpenClaw Gateway: could not validate HOME_ASSISTANT_MCP_URL metadata" >&2
      exit 1
    fi
    unset metadata
    if [ "$home_assistant_metadata_status" != valid ]; then
      unset home_assistant_metadata_status
      printf '%s\n' "refusing to start OpenClaw Gateway: HOME_ASSISTANT_MCP_URL metadata is absent or invalid" >&2
      exit 1
    fi
    unset home_assistant_metadata_status
    if ! home_assistant_url=$(
      "$openclaw" secrets store get HOME_ASSISTANT_MCP_URL --plain 2>/dev/null
    ); then
      printf '%s\n' "refusing to start OpenClaw Gateway: could not retrieve HOME_ASSISTANT_MCP_URL from the store" >&2
      exit 1
    fi
    if ! printf '%s' "$home_assistant_url" | "$jq" -eRs 'test("^http://pikachu:9584/private_[A-Za-z0-9]+$")' >/dev/null 2>&1; then
      printf '%s\n' "refusing to start OpenClaw Gateway: HOME_ASSISTANT_MCP_URL is absent or invalid" >&2
      exit 1
    fi

    if ! printf '%s' "$home_assistant_url" |
      "$jq" -e -s --arg group_id "$telegram_group_id" \
        --argjson group_allow_from "$telegram_group_allow_from" \
        --rawfile home_assistant_url /dev/stdin '
      if (length != 1 or (.[0] | type != "object")) then error("invalid config") else .[0] end |
      .channels.telegram.groups = {($group_id): {requireMention: false}} |
      .channels.telegram.groupPolicy = "allowlist" |
      .channels.telegram.groupAllowFrom = $group_allow_from |
      .mcp.servers["home-assistant"].url = $home_assistant_url
    ' "$OPENCLAW_CONFIG_GENERATION" >"$tmp_config" 2>/dev/null || \
      ! "$jq" -e 'type == "object"' "$tmp_config" >/dev/null 2>&1 || \
      ! "$chmod" 600 -- "$tmp_config" 2>/dev/null || \
      ! "$mv" -f -- "$tmp_config" "$runtime_config" 2>/dev/null; then
      printf '%s\n' "refusing to start OpenClaw Gateway: could not materialize runtime config" >&2
      exit 1
    fi
    tmp_config=
    unset telegram_group_id telegram_group_allow_from home_assistant_url
    export OPENCLAW_CONFIG_PATH="$runtime_config"

    if ! camofox_key=$(
      "$openclaw" secrets store get CAMOFOX_ACCESS_KEY --plain 2>/dev/null
    ); then
      printf '%s\n' "refusing to start OpenClaw Gateway: could not retrieve CAMOFOX_ACCESS_KEY from the store" >&2
      exit 1
    fi
    if [ -z "$camofox_key" ]; then
      printf '%s\n' "refusing to start OpenClaw Gateway: CAMOFOX_ACCESS_KEY is empty" >&2
      exit 1
    fi
    export CAMOFOX_ACCESS_KEY="$camofox_key"

    if ! obsidian_token=$(
      "$openclaw" secrets store get OBSIDIAN_LOCAL_REST_API_KEY --plain 2>/dev/null
    ); then
      printf '%s\n' "refusing to start OpenClaw Gateway: could not retrieve OBSIDIAN_LOCAL_REST_API_KEY from the store" >&2
      exit 1
    fi
    if [ -z "$obsidian_token" ]; then
      printf '%s\n' "refusing to start OpenClaw Gateway: OBSIDIAN_LOCAL_REST_API_KEY is empty" >&2
      exit 1
    fi
    export OBSIDIAN_LOCAL_REST_API_KEY="$obsidian_token"

    deadline=$(( $(/bin/date +%s) + 180 ))
    while ! info=$(
      "$podman" --connection openclaw-sandbox info --format json 2>/dev/null
    ) || ! printf '%s\n' "$info" | "$jq" -e '.host.security.rootless == true' >/dev/null 2>&1; do
      if [ "$(/bin/date +%s)" -ge "$deadline" ]; then
        printf '%s\n' \
          "refusing to start OpenClaw Gateway: openclaw-sandbox was not reachable as a rootless Podman machine within 180 seconds" >&2
        exit 1
      fi
      /bin/sleep 2
    done

    if ! "$machine_checker"; then
      printf '%s\n' "refusing to start OpenClaw Gateway: openclaw-sandbox machine configuration check failed" >&2
      exit 1
    fi

    ${lib.getExe pkgs.openclaw-languagetool-mcp-image}

    exec "$openclaw" gateway --port 18789
  '';
in
{
  assertions = [
    {
      assertion = lib.getVersion openclawPackage == "2026.9.3";
      message = "OpenClaw Gateway must be exactly 2026.9.3";
    }
    {
      assertion = lib.getVersion openclawApp == "2026.9.3";
      message = "OpenClaw.app must be exactly 2026.9.3";
    }
    {
      assertion = listIsDuplicateFree macAppsMcpTools;
      message = "Mac Apps MCP allowed tools must not contain duplicates";
    }
    {
      assertion = listsAreDisjoint macAppsMcpTools macAppsMcpDeniedTools;
      message = "Mac Apps MCP allowed and denied tools must be disjoint";
    }
    {
      assertion = builtins.all (
        tool: !(lib.hasPrefix "reminders_" tool || lib.hasPrefix "notes_" tool)
      ) macAppsMcpTools;
      message = "Mac Apps MCP tools must not include reminders_ or notes_ tools";
    }
    {
      assertion = listIsDuplicateFree obsidianMcpTools;
      message = "Obsidian MCP allowed tools must not contain duplicates";
    }
    {
      assertion = listsAreDisjoint obsidianMcpTools obsidianMcpDeniedTools;
      message = "Obsidian MCP allowed and denied tools must be disjoint";
    }
    {
      assertion = listIsDuplicateFree anytypeMcpTools;
      message = "Anytype MCP allowed tools must not contain duplicates";
    }
    {
      assertion = listsAreDisjoint anytypeMcpTools anytypeMcpDeniedTools;
      message = "Anytype MCP allowed and denied tools must be disjoint";
    }
    {
      assertion = listIsDuplicateFree substackMcpAllowedTools;
      message = "Substack MCP allowed tools must not contain duplicates";
    }
    {
      assertion = listsAreDisjoint substackMcpAllowedTools substackMcpDeniedTools;
      message = "Substack MCP allowed and denied tools must be disjoint";
    }
    {
      assertion = listIsDuplicateFree homeAssistantMcpTools;
      message = "Home Assistant MCP allowed tools must not contain duplicates";
    }
    {
      assertion = listsAreDisjoint homeAssistantMcpTools homeAssistantMcpDeniedTools;
      message = "Home Assistant MCP allowed and denied tools must be disjoint";
    }
    {
      assertion = builtins.all (
        tool: !(lib.hasInfix "calendar" tool || lib.hasInfix "todo" tool)
      ) homeAssistantMcpTools;
      message = "Home Assistant MCP allowed tools must not include calendar or todo tools";
    }
  ];

  imports = [ ./darwin.nix ];

  home.activation.openclawRuntimeStateDirectoryMaintenance =
    lib.hm.dag.entryAfter [ "writeBoundary" ]
      ''
        ${install} -d -m 0700 -- "${state}" "${state}/logs"
      '';

  home.packages = [
    (lib.hiPrio openclawCliWrapper)
  ];

  programs.openclaw = {
    enable = true;
    launchd.label = "ai.openclaw.gateway";
    package = openclawPackage;
    appPackage = openclawApp;
    installApp = false;
    stateDir = state;
    workspaceDir = workspace;
    workspace.files."avatars/alfred.png" = ./assets/alfred.png;
    runtimePlugins = [
      "llama-cpp"
      "camofox-browser"
    ];
    runtimePackages = [
      pkgs.podman
      pkgs.openclaw-llama-server
      pkgs.openclaw-whisper
    ];

    config = {
      gateway = {
        mode = "local";
        port = 18789;
        bind = "loopback";
        auth = {
          mode = "token";
          # The native app's Swift resolver supports environment interpolation,
          # but cannot resolve OpenClaw SecretRefs.
          token = "$" + "{OPENCLAW_GATEWAY_TOKEN}";
          allowTailscale = false;
        };
        tailscale = {
          mode = "off";
          preserveFunnel = false;
        };
        publicOrigin = "https://renekton.dusky-diatonic.ts.net:18790";
        trustedProxies = [ "127.0.0.1" ];
        controlUi = {
          enabled = true;
          allowedOrigins = [
            "http://127.0.0.1:18789"
            "http://localhost:18789"
            "https://renekton.dusky-diatonic.ts.net:18790"
          ];
        };
        nodes = {
          commands = {
            allow = [ ];
            deny = [
              "camera.list"
              "camera.ptz.status"
              "camera.snap"
              "camera.clip"
              "camera.ptz.control"
              "screen.snapshot"
              "screen.record"
              "desktop.stream"
              "computer.act"
              "mobile.ui.observe"
              "mobile.ui.act"
              "location.get"
              "notifications.list"
              "notifications.actions"
              "device.info"
              "device.status"
              "device.permissions"
              "device.health"
              "device.apps"
              "contacts.search"
              "contacts.add"
              "calendar.events"
              "calendar.add"
              "callLog.search"
              "reminders.list"
              "reminders.add"
              "photos.latest"
              "motion.activity"
              "motion.pedometer"
              "health.summary"
              "sms.send"
              "sms.search"
              "talk.ptt.start"
              "talk.ptt.stop"
              "talk.ptt.cancel"
              "talk.ptt.once"
              "watch.status"
              "watch.notify"
              "system.run.prepare"
              "system.run"
              "system.which"
              "system.notify"
              "system.execApprovals.get"
              "system.execApprovals.set"
              "fs.listDir"
              "terminal.upload"
              "browser.proxy"
              "browser.proxy.upload.v1"
              "mcp.tools.call.v1"
              "agent.cli.claude.run.v1"
            ];
          };
          allowSkills = false;
          pairing = {
            autoApproveCidrs = [ ];
            autoApproveLocal = false;
          };
          browser = {
            mode = "off";
          };
          pluginTools = {
            enabled = false;
          };
        };
        tls = {
          enabled = false;
        };
      };

      agents = {
        defaults = {
          inherit workspace;
          bootstrapMaxChars = 20000;
          bootstrapTotalMaxChars = 60000;
          skipBootstrap = true;
          contextInjection = "continuation-skip";
          model = {
            primary = "openai/gpt-5.6-sol";
            fallbacks = [ ];
          };
          utilityModel = "openai/gpt-5.6-luna";
          modelSelectionScope = "session";
          thinkingDefault = "medium";
          fastModeDefault = "auto";
          maxConcurrent = 2;
          compaction = {
            enabled = true;
            mode = "safeguard";
            keepRecentTokens = 20000;
            qualityGuard = {
              enabled = true;
              maxRetries = 1;
            };
            midTurnPrecheck.enabled = true;
            memoryFlush = {
              enabled = true;
              softThresholdTokens = 4000;
              model = "openai/gpt-5.6-luna";
            };
            notifyUser = false;
            thinkingLevel = "inherit";
            timeoutSeconds = 900;
          };
          mediaModels = {
            image = {
              primary = "openai/gpt-image-2";
              fallbacks = [ ];
            };
          };
          imageModel = {
            primary = "openai/gpt-5.6-sol";
            fallbacks = [ ];
          };
          pdfModel = {
            primary = "openai/gpt-5.6-sol";
            fallbacks = [ ];
          };
          pdfMaxMb = 20;
          pdfMaxPages = 100;
          models = {
            "openai/gpt-5.6-sol" = {
              alias = "sol";
              agentRuntime.id = "openclaw";
              codeMode = false;
            };
            "openai/gpt-5.6-luna" = {
              alias = "luna";
              agentRuntime.id = "openclaw";
              codeMode = false;
            };
          };
          heartbeat = {
            every = "0m";
          };
          subagents = {
            maxConcurrent = 1;
            maxChildrenPerAgent = 1;
            maxSpawnDepth = 1;
            runTimeoutSeconds = 900;
            delegationMode = "suggest";
            announceTimeoutMs = 900000;
          };
          sandbox = {
            backend = "podman";
            mode = "all";
            scope = "session";
            workspaceAccess = "rw";
            workspaceRoot = "/workspace";
            sessionToolsVisibility = "spawned";
            docker = {
              image = "openclaw-sandbox:bookworm-slim";
              network = "bridge";
              readOnlyRoot = true;
              capDrop = [ "ALL" ];
              tmpfs = [ "/tmp" ];
              workdir = "/workspace";
              pidsLimit = 256;
              cpus = 2;
              memory = "1g";
              memorySwap = "1g";
              binds = [ ];
            };
            prune = {
              idleHours = 6;
              maxAgeDays = 7;
            };
          };
        };
        entries.main = {
          identity = {
            name = "Alfred";
            theme = "Zwięzły, bezpośredni i dyskretny — technicznie dociekliwy, bez zbędnego hałasu i bez fluffu.";
            emoji = "🤵‍♂️";
            avatar = "avatars/alfred.png";
          };
          runtime = {
            type = "embedded";
          };
          sandbox = {
            backend = "podman";
            mode = "all";
          };
          skills = [
            "control-ui"
            "diagram-maker"
            "spike"
            "weather"
          ];
        };
      };

      models = {
        mode = "merge";
        providers.llama-cpp = {
          baseUrl = "http://127.0.0.1:19432/v1";
          api = "openai-completions";
          localService = {
            command = lib.getExe pkgs.openclaw-llama-server;
            healthUrl = "http://127.0.0.1:19432/health";
            readyTimeoutMs = 30000;
            idleStopMs = 600000;
            args = [
              "--host"
              "127.0.0.1"
              "--port"
              "19432"
              "--model"
              "${pkgs.openclaw-embeddinggemma}/share/openclaw/models/embeddinggemma-300m-qat-Q8_0.gguf"
              "--embedding"
              "--cache-ram"
              "0"
              "--no-cache-prompt"
              "--ubatch-size"
              "1024"
              "--batch-size"
              "1024"
              "--parallel"
              "1"
              "--metrics"
              "--no-ui"
            ];
          };
          models = [ ];
        };
      };

      tools = {
        profile = "minimal";
        alsoAllow =
          approvedTools
          ++ camofoxTools
          ++ macAppsMcpPolicyIds
          ++ obsidianMcpPolicyIds
          ++ anytypeMcpPolicyIds
          ++ substackMcpPolicyIds
          ++ languagetoolMcpPolicyIds
          ++ homeAssistantMcpPolicyIds;
        deny = deniedTools;
        fs.workspaceOnly = true;
        exec = {
          applyPatch = {
            enabled = true;
            workspaceOnly = true;
          };
          host = "sandbox";
          mode = "full";
          timeoutSeconds = 900;
        };
        elevated = {
          enabled = false;
        };
        codeMode = false;
        toolSearch = {
          mode = "directory";
          searchDefaultLimit = 5;
          maxSearchLimit = 10;
        };
        agentToAgent = {
          enabled = false;
          allow = [ ];
        };
        sessions = {
          visibility = "tree";
        };
        sandbox.tools.allow =
          sandboxTools
          ++ camofoxTools
          ++ macAppsMcpPolicyIds
          ++ obsidianMcpPolicyIds
          ++ anytypeMcpPolicyIds
          ++ substackMcpPolicyIds
          ++ languagetoolMcpPolicyIds
          ++ homeAssistantMcpPolicyIds;
        subagents.tools.allow = [
          "session_status"
          "read"
          "write"
          "edit"
          "apply_patch"
          "exec"
          "process"
          "web_search"
          "web_fetch"
          "memory_search"
          "memory_get"
          "view_image"
          "pdf"
        ];
        swarm = false;
        updatePlan = true;
        web = {
          search = {
            enabled = true;
            openaiCodex = {
              enabled = true;
              mode = "live";
            };
          };
          fetch = {
            enabled = true;
            readability = true;
            ssrfPolicy.dangerouslyAllowPrivateNetwork = false;
          };
        };
        media = {
          concurrency = 1;
          models = [
            {
              type = "cli";
              command = lib.getExe pkgs.openclaw-whisper;
              args = [ "{{AttachmentPath}}" ];
              capabilities = [ "audio" ];
              maxBytes = 20971520;
              timeoutSeconds = 360;
            }
          ];
          audio = {
            enabled = true;
            maxBytes = 20971520;
            attachments = {
              mode = "first";
              maxAttachments = 1;
            };
            scope = {
              default = "deny";
              rules = [
                {
                  action = "allow";
                  match = {
                    channel = "telegram";
                    chatType = "direct";
                  };
                }
                {
                  action = "allow";
                  match = {
                    channel = "telegram";
                    chatType = "group";
                  };
                }
                {
                  action = "allow";
                  match = {
                    channel = "webchat";
                    chatType = "direct";
                  };
                }
              ];
            };
          };
          video.enabled = false;
        };
      };
      memory = {
        search = {
          enabled = true;
          provider = "local";
          model = "local";
          fallback = "none";
          sources = [
            "memory"
            "sessions"
          ];
          rememberAcrossConversations = true;
          experimental.sessionMemory = true;
          local.modelPath = "${pkgs.openclaw-embeddinggemma}/share/openclaw/models/embeddinggemma-300m-qat-Q8_0.gguf";
          cache.enabled = true;
          store.vector.enabled = true;
        };
      };
      plugins = {
        enabled = true;
        allow = enabledPluginIds;
        deny = disabledPluginIds;
        slots.memory = "memory-core";
        entries =
          lib.genAttrs enabledPluginIds (_: {
            enabled = true;
          })
          // lib.genAttrs disabledPluginIds (_: {
            enabled = false;
          })
          // {
            "active-memory" = {
              enabled = true;
              config = {
                enabled = true;
                mode = "escalate";
                agents = [ "main" ];
                allowedChatTypes = [ "direct" ];
                model = "openai/gpt-5.6-luna";
                thinking = "off";
                fastMode = "auto";
                queryMode = "recent";
                promptStyle = "balanced";
                timeoutMs = 15000;
                maxSummaryChars = 220;
                toolsAllow = [
                  "memory_search"
                  "memory_get"
                ];
                persistTranscripts = false;
                logging = true;
              };
            };
            "device-pair" = {
              enabled = true;
              config.publicUrl = "wss://renekton.dusky-diatonic.ts.net:18790";
            };
            "camofox-browser" = {
              enabled = true;
              config = {
                url = "http://127.0.0.1:9377";
                autoStart = false;
              };
            };
          };
      };
      skills = {
        allowBundled = [
          "control-ui"
          "diagram-maker"
          "spike"
          "weather"
        ];
        install.allowUploadedArchives = false;
        workshop.autonomous.mode = "off";
      };
      channels = {
        telegram = {
          enabled = true;
          botToken = secret "TELEGRAM_ALFRED_BOT_TOKEN";
          dmPolicy = "pairing";
          allowFrom = [ ];
          groupPolicy = "allowlist";
          groupAllowFrom = [ ];
          groups = { };
          configWrites = false;
          mediaMaxMb = 20;
          richMessages = true;
          network.dangerouslyAllowPrivateNetwork = false;
          streaming = {
            mode = "progress";
            chunkMode = "newline";
            progress = {
              toolProgress = true;
              commandText = "status";
            };
          };
          actions = {
            reactions = true;
            sendMessage = true;
            poll = false;
            deleteMessage = false;
            editMessage = false;
            sticker = false;
            createForumTopic = false;
            editForumTopic = false;
          };
          execApprovals = {
            enabled = false;
            approvers = [ ];
          };
        };
      };
      messages = {
        ackReactionScope = "direct";
        visibleReplies = "automatic";
      };
      cron = {
        enabled = true;
        skipMissedJobs = true;
        sessionRetention = "30d";
        triggers.enabled = false;
      };
      browser = {
        enabled = false;
        evaluateEnabled = false;
        allowSystemProfileImport = false;
      };
      tts = {
        enabled = false;
        auto = "off";
      };
      discovery.mdns.mode = "minimal";
      mcp = {
        servers = {
          "mac-apps" = {
            enabled = true;
            transport = "stdio";
            command = "${macAppsMcpHostApp}/Contents/MacOS/Mac Apps MCP Host";
            args = [ (lib.getExe pkgs.mac-apps-mcp-server) ];
            env = {
              MACOS_MCP_READONLY = "false";
              MACOS_MCP_CONFIRM_DESTRUCTIVE = "true";
              MACOS_MCP_WRITE_RATE_LIMIT = "1";
            };
            connectionTimeoutMs = 10000;
            requestTimeoutMs = 300000;
            supportsParallelToolCalls = false;
            toolFilter = {
              include = macAppsMcpTools;
              exclude = macAppsMcpDeniedTools;
            };
          };
          obsidian = {
            enabled = true;
            url = "https://127.0.0.1:27124/mcp/";
            transport = "streamable-http";
            headers.Authorization = "Bearer $" + "{OBSIDIAN_LOCAL_REST_API_KEY}";
            # Scoped only to the plugin's fixed self-signed loopback endpoint.
            sslVerify = false;
            connectionTimeoutMs = 10000;
            requestTimeoutMs = 300000;
            supportsParallelToolCalls = false;
            toolFilter = {
              include = obsidianMcpTools;
              exclude = obsidianMcpDeniedTools;
            };
          };
          anytype = {
            enabled = true;
            transport = "stdio";
            command = lib.getExe anytypeMcp;
            args = [ ];
            connectionTimeoutMs = 10000;
            requestTimeoutMs = 300000;
            supportsParallelToolCalls = false;
            toolFilter = {
              include = anytypeMcpTools;
              exclude = anytypeMcpDeniedTools;
            };
          };
          substack = {
            enabled = true;
            transport = "stdio";
            command = lib.getExe substackMcp;
            args = [ ];
            connectionTimeoutMs = 10000;
            requestTimeoutMs = 300000;
            supportsParallelToolCalls = false;
            toolFilter = {
              include = substackMcpAllowedTools;
              exclude = substackMcpDeniedTools;
            };
          };
          languagetool = {
            enabled = true;
            transport = "stdio";
            command = lib.getExe languagetoolMcp;
            args = [ ];
            connectionTimeoutMs = 10000;
            requestTimeoutMs = 180000;
            supportsParallelToolCalls = false;
            toolFilter.include = languagetoolMcpTools;
          };
          "home-assistant" = {
            enabled = true;
            # Keep a non-secret placeholder; the gateway wrapper replaces it with the Secret Store URL in the private runtime config.
            url = "https://home-assistant-mcp.invalid/";
            transport = "streamable-http";
            connectionTimeoutMs = 10000;
            requestTimeoutMs = 300000;
            supportsParallelToolCalls = false;
            toolFilter = {
              include = homeAssistantMcpTools;
              exclude = homeAssistantMcpDeniedTools;
            };
          };
        };
        apps.enabled = false;
      };
      hooks = {
        enabled = false;
        internal = {
          enabled = false;
        };
      };
      desktop.host.enabled = false;
      cloudWorkers.desktop = false;
      commands = {
        bash = false;
        config = false;
        debug = false;
        mcp = false;
        plugins = false;
        restart = false;
      };
      logging = {
        level = "info";
        consoleLevel = "warn";
        consoleStyle = "json";
        file = "${state}/logs/gateway.jsonl";
        maxFileBytes = 10485760;
        audit = {
          enabled = true;
          messages = "off";
          executionIdentity = true;
        };
      };
      diagnostics = {
        enabled = true;
        cacheTrace.enabled = false;
        otel = {
          enabled = false;
        };
      };
      telemetry = {
        enabled = false;
      };
      update = {
        channel = "stable";
        checkOnStart = false;
        auto.enabled = false;
      };
      secrets = {
        defaults.store = "default";
        egressProxy = {
          enabled = true;
          allowedHosts = [ "api.telegram.org" ];
        };
      };
      session = {
        dmScope = "per-channel-peer";
        groupScope = "per-group";
        mainKey = "main";
      };
    };
  };

  launchd.agents."ai.openclaw.gateway".config = {
    ProgramArguments = lib.mkForce [ "${gatewayWrapper}" ];
    EnvironmentVariables = {
      CONTAINER_CONNECTION = "openclaw-sandbox";
      PATH = "${pkgs.podman}/bin:/usr/bin:/bin:/usr/sbin:/sbin";
      # Deliberately changes the plist when generated OpenClaw config changes, so Home Manager restarts the Gateway.
      OPENCLAW_CONFIG_GENERATION = toString config.home.file.".openclaw/openclaw.json".source;
    };
    StandardOutPath = lib.mkForce "${state}/logs/gateway.log";
    StandardErrorPath = lib.mkForce "${state}/logs/gateway.error.log";
    Umask = 63;
  };
}
