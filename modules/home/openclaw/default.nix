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
  source = pkgs.fetchFromGitHub {
    owner = "openclaw";
    repo = "openclaw";
    rev = "1391f7cd2d40ab5bbcf2f5f831d3a64f520e72d7";
    hash = "sha256-ZahFh0aNN3C/+IPFUXbnZOTymrsPy/LwbnVGPXcRSiw=";
  };
  secret = id: {
    source = "store";
    provider = "default";
    inherit id;
  };
  # BOOTSTRAP.md is runtime-owned; its absence marks bootstrap complete.
  docs = [
    "AGENTS.md"
    "SOUL.md"
    "IDENTITY.md"
    "USER.md"
  ];
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
  macAppsMcpTools = [
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
  macAppsMcpPolicyIds = map (tool: "mac-apps__${tool}") macAppsMcpTools;
  obsidianMcpTools = [
    "vault_list"
    "vault_read"
    "vault_get_document_map"
    "active_file_get_path"
    "search_query"
    "search_simple"
    "tag_list"
    "command_list"
  ];
  obsidianMcpPolicyIds = map (tool: "obsidian__${tool}") obsidianMcpTools;
  anytypeMcpTools = [
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
  anytypeMcpPolicyIds = map (tool: "anytype__${tool}") anytypeMcpTools;
  substackMcpTools = [
    "get_analytics"
    "get_dashboard_summary"
    "get_email_stats"
    "get_growth_sources"
    "get_revenue_summary"
    "get_post_comments"
    "get_draft"
    "list_drafts"
    "list_scheduled_posts"
    "preview_draft_body"
    "get_sections"
    "list_scheduled_notes"
    "list_notes"
    "list_posts"
    "get_post_by_id"
    "search_posts"
    "get_post_stats"
    "rank_posts"
    "get_publication_settings"
    "get_user_profile"
    "list_contributors"
    "get_import_status"
    "search_publications"
    "list_subscriptions"
    "list_reader_posts"
    "get_reader_post"
    "get_reader_feed"
    "get_profile_feed"
    "get_comment_thread"
    "list_subscribers"
    "export_subscribers"
    "get_subscriber_count"
    "list_publication_tags"
    "get_post_tags"
    "list_templates"
  ];
  substackMcpPolicyIds = map (tool: "substack__${tool}") substackMcpTools;
  substackMcpExcludedTools = [
    "create_draft"
    "update_draft"
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
    "get_post"
    "get_publication_info"
    "research_creator_posts"
    "research_creator_notes"
    "compare_publications"
    "scrape_post"
  ];
  macAppsMcpHostApp = "${home}/Applications/Home Manager Apps/Mac Apps MCP Host.app";
  deniedTools = [
    "message"
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
  openclawPackageSet = pkgs.openclawPackages.withTools { excludeToolNames = [ "git" ]; };
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
  openssl = lib.getExe pkgs.openssl;
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
      export SUBSTACK_READ_ONLY=1
      export SUBSTACK_ALLOW_DESTRUCTIVE=0
      export SUBSTACK_MCP_HOME=/dev/null
      unset publication_url session_token
      exec ${lib.getExe pkgs.substack-mcp} "$@"
    '';
  };
  substackBootstrap = pkgs.writeShellApplication {
    name = "substack-openclaw-bootstrap";
    runtimeInputs = [
      pkgs.jq
      openclawPackage
    ];
    text = ''
      set -euo pipefail

      openclaw=${lib.escapeShellArg openclaw}
      jq=${lib.escapeShellArg jq}
      validate_metadata() {
        # shellcheck disable=SC2016
        "$jq" -e '
          [ .[]? | select(.name == "SUBSTACK_PUBLICATION_URL") ] as $url |
          [ .[]? | select(.name == "SUBSTACK_SESSION_TOKEN") ] as $token |
          ($url | length) == 1 and ($token | length) == 1 and
          $url[0].kind == "env" and $token[0].kind == "env" and
          (($url[0].allowedHosts // []) == []) and
          (($token[0].allowedHosts // []) == [])
        ' <<<"$metadata" >/dev/null
      }
      validate_values() {
        if ! stored_url=$("$openclaw" secrets store get SUBSTACK_PUBLICATION_URL --plain 2>/dev/null); then
          return 1
        fi
        if ! stored_token=$("$openclaw" secrets store get SUBSTACK_SESSION_TOKEN --plain 2>/dev/null); then
          return 1
        fi
        if [ -z "$stored_url" ] || [ -z "$stored_token" ]; then
          return 1
        fi
        normalized_url=$(${pkgs.coreutils}/bin/tr '[:upper:]' '[:lower:]' <<<"$stored_url")
        if [[ "$stored_url" != "$normalized_url" ]] || \
          [[ ! "$normalized_url" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.substack\.com$ ]]; then
          return 1
        fi
      }
      metadata=$("$openclaw" secrets store list --json)
      # shellcheck disable=SC2016
      url_status=$("$jq" -r '
        [ .[]? | select(.name == "SUBSTACK_PUBLICATION_URL") ] as $e |
        if ($e | length) == 0 then "absent"
        elif ($e | length) == 1 and $e[0].kind == "env" and (($e[0].allowedHosts // []) == []) then "valid"
        else "invalid"
        end
      ' <<<"$metadata")
      # shellcheck disable=SC2016
      token_status=$("$jq" -r '
        [ .[]? | select(.name == "SUBSTACK_SESSION_TOKEN") ] as $e |
        if ($e | length) == 0 then "absent"
        elif ($e | length) == 1 and $e[0].kind == "env" and (($e[0].allowedHosts // []) == []) then "valid"
        else "invalid"
        end
      ' <<<"$metadata")
      if [ "$url_status" = invalid ] || [ "$token_status" = invalid ]; then
        printf '%s\n' "refusing bootstrap: Substack Secret Store metadata is unexpected; no update was performed." >&2
        exit 1
      fi
      if [ "$url_status" = valid ] && [ "$token_status" = valid ]; then
        if validate_values; then
          printf '%s\n' "Substack Secret Store entries already have approved metadata and valid values; preserving them."
          unset stored_url stored_token normalized_url
          exit 0
        fi
        unset stored_url stored_token normalized_url
        printf '%s\n' \
          "refusing bootstrap: Substack Secret Store values are empty or invalid." \
          "Correct them intentionally with the OpenClaw Secret Store prompts; no overwrite was performed." >&2
        exit 1
      fi
      if [[ ! -t 0 || ! -t 1 ]]; then
        printf '%s\n' "refusing bootstrap: Substack credentials are absent and require an interactive terminal." >&2
        exit 1
      fi
      if [ "$url_status" = absent ]; then
        printf '%s' "Substack publication hostname (*.substack.com): " >&2
        IFS= read -r publication_url
        publication_url=$(${pkgs.coreutils}/bin/tr '[:upper:]' '[:lower:]' <<<"$publication_url")
        if [[ ! "$publication_url" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.substack\.com$ ]]; then
          printf '%s\n' "refusing bootstrap: publication must be a bare canonical *.substack.com hostname." >&2
          exit 1
        fi
        if ! printf '%s' "$publication_url" | "$openclaw" secrets store set SUBSTACK_PUBLICATION_URL --kind env --value-file -; then
          printf '%s\n' "refusing bootstrap: could not store the Substack publication hostname." >&2
          exit 1
        fi
        unset publication_url
      fi
      if [ "$token_status" = absent ]; then
        printf '%s\n' "Enter the Substack session token (masked): " >&2
        if ! "$openclaw" secrets store set SUBSTACK_SESSION_TOKEN --kind env; then
          printf '%s\n' "refusing bootstrap: could not store the Substack session token." >&2
          exit 1
        fi
      fi
      unset metadata
      metadata=$("$openclaw" secrets store list --json)
      if ! validate_metadata || ! validate_values; then
        unset stored_url stored_token normalized_url
        printf '%s\n' \
          "refusing bootstrap: Substack metadata or values were not created exactly as required." \
          "Correct them intentionally with the OpenClaw Secret Store prompts; no automatic overwrite was performed." >&2
        exit 1
      fi
      unset stored_url stored_token normalized_url
    '';
  };
  anytypeBootstrap = pkgs.writeShellApplication {
    name = "anytype-openclaw-bootstrap";
    runtimeInputs = [
      pkgs.gawk
      pkgs.jq
      openclawPackage
      pkgs.anytype-cli
    ];
    text = ''
      set -euo pipefail

      openclaw=${lib.escapeShellArg openclaw}
      anytype_cli=${lib.escapeShellArg (lib.getExe pkgs.anytype-cli)}
      jq=${lib.escapeShellArg jq}

      metadata=$("$openclaw" secrets store list --json)
      # shellcheck disable=SC2016
      anytype_status=$("$jq" -r --arg name ANYTYPE_API_KEY '
        [ .[]? | select(.name == $name) ] as $entries |
        if ($entries | length) == 0 then "absent"
        elif ($entries | length) == 1
          and $entries[0].kind == "env"
          and (($entries[0].allowedHosts // []) == []) then "valid"
        else "invalid"
        end
      ' <<<"$metadata")

      case "$anytype_status" in
        valid)
          printf '%s\n' "ANYTYPE_API_KEY already exists with approved metadata; preserving it."
          ;;
        invalid)
          printf '%s\n' \
            "refusing bootstrap: ANYTYPE_API_KEY has unexpected or duplicate metadata." \
            "Complete account setup first via anytype-cli auth create <name>; no implicit rotation/update was performed." >&2
          exit 1
          ;;
        absent)
          if ! "$openclaw" secrets store set --help >/dev/null 2>&1 || \
            ! "$openclaw" secrets store list --help >/dev/null 2>&1; then
            printf '%s\n' \
              "refusing bootstrap: this OpenClaw CLI does not support the Secret Store." \
              "Complete account setup first via anytype-cli auth create <name>." >&2
            exit 1
          fi
          if ! api_key=$(
            "$anytype_cli" --no-update-check auth apikey create openclaw | \
              gawk '
                BEGIN { found = 0; valid = 1 }
                /^Key: [^[:space:]]+$/ {
                  if (found++) valid = 0
                  key = substr($0, 6)
                }
                END {
                  if (!valid || found != 1) exit 1
                  print key
                }
              '
          ); then
            printf '%s\n' \
              "refusing bootstrap: could not create the Anytype API key or parse its response." \
              "Complete account setup first via anytype-cli auth create <name>." >&2
            exit 1
          fi
          if [ -z "$api_key" ]; then
            unset api_key
            printf '%s\n' \
              "refusing bootstrap: Anytype API key creation returned an empty key." \
              "Complete account setup first via anytype-cli auth create <name>." >&2
            exit 1
          fi
          if ! printf '%s' "$api_key" | \
            "$openclaw" secrets store set ANYTYPE_API_KEY --kind env --value-file -; then
            unset api_key
            printf '%s\n' \
              "refusing bootstrap: could not store the Anytype API key." \
              "Complete account setup first via anytype-cli auth create <name>." >&2
            exit 1
          fi
          unset api_key
          metadata=$(
            "$openclaw" secrets store list --json
          )
          # shellcheck disable=SC2016
          if ! "$jq" -e --arg name ANYTYPE_API_KEY '
            [ .[]? | select(.name == $name) ] as $entries |
            ($entries | length) == 1 and
            $entries[0].kind == "env" and
            (($entries[0].allowedHosts // []) == [])
          ' <<<"$metadata" >/dev/null; then
            printf '%s\n' \
              "refusing bootstrap: ANYTYPE_API_KEY metadata was not created exactly as required." \
              "Complete account setup first via anytype-cli auth create <name>." >&2
            exit 1
          fi
          ;;
        *)
          printf '%s\n' \
            "refusing bootstrap: unexpected ANYTYPE_API_KEY metadata status." \
            "Complete account setup first via anytype-cli auth create <name>." >&2
          exit 1
          ;;
      esac
    '';
  };
  camofoxBootstrap = pkgs.writeShellApplication {
    name = "camofox-openclaw-bootstrap";
    runtimeInputs = [
      pkgs.jq
      pkgs.openssl
      openclawPackage
    ];
    text = ''
      set -euo pipefail

      openclaw=${lib.escapeShellArg openclaw}
      jq=${lib.escapeShellArg jq}
      openssl=${lib.escapeShellArg openssl}

      metadata=$("$openclaw" secrets store list --json)
      # shellcheck disable=SC2016
      status=$("$jq" -r --arg name CAMOFOX_ACCESS_KEY '
        [ .[]? | select(.name == $name) ] as $entries |
        if ($entries | length) == 0 then "absent"
        elif ($entries | length) == 1
          and $entries[0].kind == "env"
          and (($entries[0].allowedHosts // []) == []) then "valid"
        else "invalid"
        end
      ' <<<"$metadata")

      case "$status" in
        valid)
          printf '%s\n' "CAMOFOX_ACCESS_KEY already exists with approved metadata; preserving it."
          ;;
        invalid)
          printf '%s\n' "refusing bootstrap: CAMOFOX_ACCESS_KEY has unexpected or duplicate metadata." >&2
          exit 1
          ;;
        absent)
          "$openssl" rand -hex 32 | \
            "$openclaw" secrets store set CAMOFOX_ACCESS_KEY \
              --kind env --value-file -
          metadata=$("$openclaw" secrets store list --json)
          # shellcheck disable=SC2016
          if ! "$jq" -e --arg name CAMOFOX_ACCESS_KEY '
            [ .[]? | select(.name == $name) ] as $entries |
            ($entries | length) == 1 and
            $entries[0].kind == "env" and
            (($entries[0].allowedHosts // []) == [])
          ' <<<"$metadata" >/dev/null; then
            printf '%s\n' "refusing bootstrap: CAMOFOX_ACCESS_KEY metadata was not created exactly as required." >&2
            exit 1
          fi
          ;;
        *)
          printf '%s\n' "refusing bootstrap: unexpected CAMOFOX_ACCESS_KEY metadata status." >&2
          exit 1
          ;;
      esac
    '';
  };
  seed = pkgs.writeShellScript "openclaw-seed-workspace" ''
    set -eu
    ${install} -d -m 700 ${lib.escapeShellArg state}
    ${install} -d -m 700 ${lib.escapeShellArg state}/logs
    ${install} -d -m 700 ${lib.escapeShellArg workspace}
    for name in ${lib.concatStringsSep " " docs}; do
      if [ ! -e ${lib.escapeShellArg workspace}/"$name" ]; then
        ${install} -m 0644 ${source}/docs/reference/templates/"$name" ${lib.escapeShellArg workspace}/"$name"
      fi
    done
  '';
  bootstrap = pkgs.writeShellApplication {
    name = "openclaw-bootstrap";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      openclawPackage
      pkgs.openssl
      camofoxBootstrap
      substackBootstrap
    ];
    text = ''
      set -euo pipefail

      openclaw=${lib.escapeShellArg openclaw}
      openssl=${lib.escapeShellArg openssl}
      jq=${lib.escapeShellArg jq}
      install=${lib.escapeShellArg install}
      state=${lib.escapeShellArg state}

      "$install" -d -m 700 -- "$state"
      "$install" -d -m 700 -- "$state/logs"
      export OPENCLAW_STATE_DIR="$state"

      version=$("$openclaw" --version)
      if [[ "$version" != "OpenClaw 2026.9.3 (1391f7c)" ]]; then
        printf '%s\n' "refusing bootstrap: expected OpenClaw 2026.9.3 (1391f7c), got: $version" >&2
        exit 1
      fi
      "$openclaw" secrets store set --help >/dev/null
      "$openclaw" secrets store list --help >/dev/null
      "$openclaw" secrets audit --help >/dev/null
      camofox-openclaw-bootstrap
      substack-openclaw-bootstrap

      metadata=$("$openclaw" secrets store list --json)
      # shellcheck disable=SC2016
      gateway_status=$("$jq" -r --arg name OPENCLAW_GATEWAY_TOKEN '
        [ .[]? | select(.name == $name) ] as $entries |
        if ($entries | length) == 0 then "absent"
        elif ($entries | length) == 1
          and $entries[0].kind == "env"
          and (($entries[0].allowedHosts // []) == []) then "valid"
        elif ($entries | length) == 1
          and $entries[0].kind == "secret"
          and (($entries[0].allowedHosts // []) == []) then "wrong-kind"
        else "invalid"
        end
      ' <<<"$metadata")
      case "$gateway_status" in
        valid)
          printf '%s\n' "OPENCLAW_GATEWAY_TOKEN already exists with approved metadata; preserving it."
          ;;
        wrong-kind)
          printf '%s\n' \
            "OPENCLAW_GATEWAY_TOKEN exists as a SecretRef (kind=secret), but the desktop app requires kind=env." \
            "Re-enter it intentionally with the masked CLI prompt: openclaw secrets store set OPENCLAW_GATEWAY_TOKEN --kind env" >&2
          if [[ ! -t 0 || ! -t 1 ]]; then
            printf '%s\n' \
              "refusing bootstrap: correcting OPENCLAW_GATEWAY_TOKEN requires an interactive terminal; no rotation/update was performed." >&2
            exit 1
          fi
          "$openclaw" secrets store set OPENCLAW_GATEWAY_TOKEN --kind env
          metadata=$("$openclaw" secrets store list --json)
          # shellcheck disable=SC2016
          if ! "$jq" -e --arg name OPENCLAW_GATEWAY_TOKEN '
            [ .[]? | select(.name == $name) ] as $entries |
            ($entries | length) == 1 and
            $entries[0].kind == "env" and
            (($entries[0].allowedHosts // []) == [])
          ' <<<"$metadata" >/dev/null; then
            printf '%s\n' "refusing bootstrap: OPENCLAW_GATEWAY_TOKEN metadata was not corrected to kind=env." >&2
            exit 1
          fi
          ;;
        invalid)
          printf '%s\n' \
            "refusing bootstrap: OPENCLAW_GATEWAY_TOKEN has unexpected metadata." \
            "The operator must intentionally re-enter it to correct metadata; no implicit rotation/update was performed." >&2
          exit 1
          ;;
        absent)
          printf '%s\n' "OPENCLAW_GATEWAY_TOKEN is absent; generating it."
          "$openssl" rand -hex 32 | \
            "$openclaw" secrets store set OPENCLAW_GATEWAY_TOKEN \
              --kind env --value-file -
          ;;
        *)
          printf '%s\n' "refusing bootstrap: unexpected metadata status: $gateway_status" >&2
          exit 1
          ;;
      esac

      metadata=$("$openclaw" secrets store list --json)
      # shellcheck disable=SC2016
      telegram_status=$("$jq" -r --arg name TELEGRAM_ALFRED_BOT_TOKEN '
        [ .[]? | select(.name == $name) ] as $entries |
        if ($entries | length) == 0 then "absent"
        elif ($entries | length) == 1
          and $entries[0].kind == "secret"
          and $entries[0].allowedHosts == ["api.telegram.org"] then "valid"
        else "invalid"
        end
      ' <<<"$metadata")
      case "$telegram_status" in
        valid)
          printf '%s\n' "TELEGRAM_ALFRED_BOT_TOKEN already exists with approved host metadata; preserving it."
          ;;
        invalid)
          printf '%s\n' \
            "refusing bootstrap: TELEGRAM_ALFRED_BOT_TOKEN has unexpected kind or allowedHosts metadata." \
            "The operator must intentionally re-enter it to correct metadata; no implicit rotation/update was performed." >&2
          exit 1
          ;;
        absent)
          if [[ ! -t 0 || ! -t 1 ]]; then
            printf '%s\n' \
              "refusing bootstrap: TELEGRAM_ALFRED_BOT_TOKEN is absent and requires an interactive terminal for the masked prompt." >&2
            exit 1
          fi
          "$openclaw" secrets store set TELEGRAM_ALFRED_BOT_TOKEN \
            --kind secret --allow-host api.telegram.org
          ;;
        *)
          printf '%s\n' "refusing bootstrap: unexpected metadata status: $telegram_status" >&2
          exit 1
          ;;
      esac

      obsidian_settings="${home}/Documents/zk/.obsidian/plugins/obsidian-local-rest-api/data.json"
      if [ -e "$obsidian_settings" ] || [ -L "$obsidian_settings" ]; then
        if [ ! -f "$obsidian_settings" ] || [ -L "$obsidian_settings" ]; then
          printf '%s\n' \
            "refusing bootstrap: Obsidian plugin settings path exists but is not a regular file: $obsidian_settings" >&2
          exit 1
        fi
        if ! chmod 600 -- "$obsidian_settings" >/dev/null 2>&1; then
          printf '%s\n' \
            "refusing bootstrap: could not restrict Obsidian plugin settings permissions to 0600: $obsidian_settings" >&2
          exit 1
        fi
      fi

      metadata=$("$openclaw" secrets store list --json)
      # shellcheck disable=SC2016
      obsidian_status=$("$jq" -r --arg name OBSIDIAN_LOCAL_REST_API_KEY '
        [ .[]? | select(.name == $name) ] as $entries |
        if ($entries | length) == 0 then "absent"
        elif ($entries | length) == 1
          and $entries[0].kind == "env"
          and (($entries[0].allowedHosts // []) == []) then "valid"
        else "invalid"
        end
      ' <<<"$metadata")
      case "$obsidian_status" in
        valid)
          printf '%s\n' "OBSIDIAN_LOCAL_REST_API_KEY already exists with approved metadata; preserving it."
          ;;
        invalid)
          printf '%s\n' \
            "refusing bootstrap: OBSIDIAN_LOCAL_REST_API_KEY has unexpected metadata." \
            "The operator must intentionally correct it; no implicit rotation/update was performed." >&2
          exit 1
          ;;
        absent)
          if [ -r "$obsidian_settings" ] && \
            "$jq" -e '.apiKey | type == "string" and length > 0' "$obsidian_settings" >/dev/null 2>&1; then
            "$jq" -er '.apiKey | select(type == "string" and length > 0)' "$obsidian_settings" | \
              "$openclaw" secrets store set OBSIDIAN_LOCAL_REST_API_KEY \
                --kind env --value-file -
          else
            if [[ ! -t 0 || ! -t 1 ]]; then
              printf '%s\n' \
                "refusing bootstrap: OBSIDIAN_LOCAL_REST_API_KEY is unavailable from plugin settings and requires an interactive masked prompt." >&2
              exit 1
            fi
            "$openclaw" secrets store set OBSIDIAN_LOCAL_REST_API_KEY --kind env
          fi
          metadata=$("$openclaw" secrets store list --json)
          # shellcheck disable=SC2016
          if ! "$jq" -e --arg name OBSIDIAN_LOCAL_REST_API_KEY '
            [ .[]? | select(.name == $name) ] as $entries |
            ($entries | length) == 1 and
            $entries[0].kind == "env" and
            (($entries[0].allowedHosts // []) == [])
          ' <<<"$metadata" >/dev/null; then
            printf '%s\n' "refusing bootstrap: OBSIDIAN_LOCAL_REST_API_KEY metadata was not created exactly as required." >&2
            exit 1
          fi
          ;;
        *)
          printf '%s\n' "refusing bootstrap: unexpected metadata status: $obsidian_status" >&2
          exit 1
          ;;
      esac

      metadata=$("$openclaw" secrets store list --json)
      printf '%s\n' "$metadata"
      "$openclaw" secrets audit --json
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
  ];

  imports = [ ./darwin.nix ];

  home.activation.openclawSeedWorkspace =
    lib.hm.dag.entryBetween [ "openclawLaunchdRelink" ] [ "writeBoundary" ]
      ''
        ${seed}
      '';

  home.packages = [
    bootstrap
    anytypeBootstrap
    camofoxBootstrap
    substackBootstrap
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
          maxConcurrent = 4;
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
              "--ubatch-size"
              "2048"
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
          ++ substackMcpPolicyIds;
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
          ++ substackMcpPolicyIds;
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
          models = [
            {
              type = "provider";
              provider = "openai";
              model = "gpt-4o-transcribe";
              capabilities = [ "audio" ];
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
          groupPolicy = "disabled";
          groupAllowFrom = [ ];
          groups = { };
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
            sendMessage = false;
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
              MACOS_MCP_READONLY = "true";
              MACOS_MCP_CONFIRM_DESTRUCTIVE = "true";
              MACOS_MCP_WRITE_RATE_LIMIT = "1";
            };
            connectionTimeoutMs = 10000;
            requestTimeoutMs = 300000;
            supportsParallelToolCalls = false;
            toolFilter = {
              include = macAppsMcpTools;
              exclude = [
                "mail_move"
                "mail_set_flags"
              ];
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
              exclude = [
                "vault_write"
                "vault_append"
                "vault_patch"
                "vault_delete"
                "vault_move"
                "vault_copy"
                "command_execute"
                "open_file"
              ];
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
              exclude = [
                "API-create-space"
                "API-update-space"
                "API-add-list-objects"
                "API-remove-list-object"
                "API-create-object"
                "API-delete-object"
                "API-update-object"
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
              include = substackMcpTools;
              exclude = substackMcpExcludedTools;
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
