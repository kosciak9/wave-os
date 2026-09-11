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
  docs = [
    "AGENTS.md"
    "SOUL.md"
    "IDENTITY.md"
    "USER.md"
    "BOOTSTRAP.md"
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
    "group:plugins"
    "bundle-mcp"
    "mcp"
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
    "xai"
  ];
  pluginIds = [
    "openai"
    "telegram"
    "memory-core"
    "active-memory"
    "llama-cpp"
    "document-extract"
    "web-readability"
    "device-pair"
  ];
  openclawPackageSet = pkgs.openclawPackages.withTools { excludeToolNames = [ "git" ]; };
  openclawApp = pkgs.openclawPackages.openclaw-app;
  openclawPackage = openclawPackageSet.openclaw.override {
    openclaw-app = openclawApp;
  };
  install = lib.getExe' pkgs.coreutils "install";
  openclaw = lib.getExe openclawPackage;
  openssl = lib.getExe pkgs.openssl;
  jq = lib.getExe pkgs.jq;
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

      metadata=$("$openclaw" secrets store list --json)
      # shellcheck disable=SC2016
      gateway_status=$("$jq" -r --arg name OPENCLAW_GATEWAY_TOKEN '
        [ .[]? | select(.name == $name) ] as $entries |
        if ($entries | length) == 0 then "absent"
        elif ($entries | length) == 1
          and $entries[0].kind == "secret"
          and $entries[0].allowedHosts == [] then "valid"
        else "invalid"
        end
      ' <<<"$metadata")
      case "$gateway_status" in
        valid)
          printf '%s\n' "OPENCLAW_GATEWAY_TOKEN already exists with approved metadata; preserving it."
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
              --kind secret --value-file -
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

      metadata=$("$openclaw" secrets store list --json)
      printf '%s\n' "$metadata"
      "$openclaw" secrets audit --json
    '';
  };
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

  home.packages = [ bootstrap ];

  programs.openclaw = {
    enable = true;
    package = openclawPackage;
    appPackage = openclawApp;
    installApp = false;
    stateDir = state;
    workspaceDir = workspace;
    runtimePlugins = [ "llama-cpp" ];
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
          token = secret "OPENCLAW_GATEWAY_TOKEN";
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
        alsoAllow = approvedTools;
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
        agentToAgent = {
          enabled = false;
          allow = [ ];
        };
        sessions = {
          visibility = "tree";
        };
        sandbox.tools.allow = sandboxTools;
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
        allow = pluginIds;
        deny = [
          "canvas"
          "file-transfer"
          "browser"
          "cua-computer"
          "xai"
        ];
        slots.memory = "memory-core";
        entries =
          lib.genAttrs pluginIds (_: {
            enabled = true;
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
        servers = { };
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

  launchd.agents."com.steipete.openclaw.gateway".config = {
    EnvironmentVariables.CONTAINER_CONNECTION = "openclaw-sandbox";
    StandardOutPath = lib.mkForce "${state}/logs/gateway.log";
    StandardErrorPath = lib.mkForce "${state}/logs/gateway.error.log";
    Umask = 63;
  };
}
