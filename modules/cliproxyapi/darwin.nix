{
  config,
  lib,
  pkgs,
  ...
}:
let
  user = config.system.primaryUser;
  home = config.users.users.${user}.home;
  stateDirectory = "${home}/.local/state/cliproxyapi";
  # Refreshed at runtime from opencode-models; see the config script.
  modelCatalog = "${stateDirectory}/models.json";
  opencodeHeaders = {
    User-Agent = "$User-Agent";
    x-opencode-client = "$x-opencode-client";
    x-opencode-project = "$x-opencode-project";
    x-opencode-session = "$x-opencode-session";
    x-opencode-session-id = "$x-opencode-session-id";
    x-opencode-parent-session-id = "$x-opencode-parent-session-id";
    x-opencode-request-id = "$x-opencode-request-id";
  };
  # Upstreams are named opencode-<catalog>-<protocol>; the config script fills
  # their models from that catalog entry and drops upstreams left empty.
  zenUpstream = name: {
    inherit name;
    prefix = "zen";
    base-url = "https://opencode.ai/inference/v1";
    headers = opencodeHeaders;
    models = [ ];
  };
  managementPanel = pkgs.fetchurl {
    name = "management.html";
    url = "https://github.com/router-for-me/Cli-Proxy-API-Management-Center/releases/download/v1.26.3/management.html";
    hash = "sha256-VO4p+2YcV16qzxj/lPQtcJYsW3XSWUkOI00t2PKLQPU=";
  };
  managementStatic = pkgs.linkFarm "cliproxyapi-management-v1.26.3" [
    {
      name = "management.html";
      path = managementPanel;
    }
  ];
  goUpstream = name: {
    inherit name;
    prefix = "go";
    base-url = "https://opencode.ai/inference/go/v1";
    headers = {
      User-Agent = "$User-Agent";
      x-opencode-session = "$CPA-SESSION-ID";
    };
    models = [ ];
  };
  settings = pkgs.writeText "cliproxyapi-settings.json" (
    builtins.toJSON {
      config-version = 8;
      server = {
        host = "127.0.0.1";
        port = 8317;
        trusted-proxies = [ "127.0.0.1" ];
        commercial-mode = true;
        discovery.enabled = false;
      };
      management = {
        allow-remote = true;
        secret-key = "";
        disable-control-panel = false;
        disable-auto-update-panel = true;
      };
      access.api-keys = [ ];
      oauth.auth-dir = "${stateDirectory}/auth";
      routing = {
        strategy = "round-robin";
        session-affinity = true;
        session-affinity-subagents = true;
        session-affinity-rebind-on = "quota";
        force-model-prefix = true;
        cooldown.save-cooldown-status = true;
      };
      observability.logs = {
        debug = false;
        request-log = false;
        logging-to-file = true;
        logs-max-total-size-mb = 64;
      };
      observability.usage.usage-statistics-enabled = true;
      api-keys = {
        codex = [
          (goUpstream "opencode-go-responses")
          (zenUpstream "opencode-zen-responses")
        ];
        # The Claude executor appends /v1/messages itself.
        claude = [
          ((goUpstream "opencode-go-messages") // { base-url = "https://opencode.ai/inference/go"; })
          ((zenUpstream "opencode-zen-messages") // { base-url = "https://opencode.ai/inference"; })
        ];
        openai-compatibility = [
          (goUpstream "opencode-go-chat")
          (zenUpstream "opencode-zen-chat")
        ];
      };
    }
  );
  # Writes config.json, which the running server reloads on change. A failed
  # model refresh keeps the last catalog, so an outage never empties the lists.
  writeConfig = pkgs.writeShellApplication {
    name = "cliproxyapi-config";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.diffutils
      pkgs.jq
    ];
    text = ''
      umask 077
      state=${lib.escapeShellArg stateDirectory}
      catalog=${lib.escapeShellArg modelCatalog}
      mkdir -p "$state/auth" "$state/logs"
      chmod 700 "$state" "$state/auth" "$state/logs"
      cd "$state"
      config_file=$(mktemp "$state/config.XXXXXX")
      catalog_file=$(mktemp "$state/models.XXXXXX")
      trap 'rm -f "$config_file" "$catalog_file"' EXIT
      if ${lib.getExe pkgs.opencode-models} > "$catalog_file"; then
        mv -f "$catalog_file" "$catalog"
      elif [ -s "$catalog" ]; then
        echo "Model refresh failed; keeping $catalog." >&2
      else
        echo "Model refresh failed and no catalog exists; OpenCode upstreams stay empty." >&2
        echo '{}' > "$catalog"
      fi
      jq --slurpfile models "$catalog" --slurpfile clients ${
        lib.escapeShellArg config.sops.secrets."cliproxyapi/client-keys".path
      } \
        --slurpfile go ${lib.escapeShellArg config.sops.secrets."cliproxyapi/opencode-go-keys".path} \
        --slurpfile zen ${lib.escapeShellArg config.sops.secrets."cliproxyapi/opencode-zen-keys".path} \
        --rawfile quota ${lib.escapeShellArg config.sops.secrets."cliproxyapi/quota-key".path} \
        --rawfile management ${lib.escapeShellArg config.sops.secrets."cliproxyapi/management-key".path} '
          def valid_keys: type == "array" and
            all(.[]; type == "string" and length > 0 and test("^[^\\r\\n]+$"));
          def with_keys($list):
            if ($list[0] | length) == 0 then .keys = []
            else .keys = ($list[0] | map({"api-key": .})) end;
          ($management | rtrimstr("\n")) as $management_key |
          ($quota | rtrimstr("\n")) as $quota_key |
          if ($clients[0] | valid_keys and length > 0) and ($go[0] | valid_keys) and
            ($zen[0] | valid_keys) and
            ($management_key | length > 0 and test("^[^\\r\\n]+$")) and
            ($quota_key | length >= 32 and test("^[^\\r\\n]+$")) and
            ($clients[0] | index($management_key) == null and index($quota_key) == null) and
            ($go[0] | index($quota_key) == null) and ($zen[0] | index($quota_key) == null) and
            ($quota_key != $management_key) then
            .access["api-keys"] = $clients[0] |
            .management["secret-key"] = $management_key |
            .["api-keys"] |= with_entries(.value |= (map(
              (.name | ltrimstr("opencode-") | split("-")) as [$catalog, $protocol] |
              .models = ($models[0][$catalog][$protocol] // {} | keys | map({name: .})) |
              if .name == "opencode-zen-responses" then
                with_keys($zen) | .keys |= map(. + {"disable-codex-cloaking": true})
              elif (.name | startswith("opencode-zen-")) then with_keys($zen)
              else with_keys($go) end) |
              # An empty list would expose the executor's built-in models.
              map(select(.models != []))))
          else error("CLIProxyAPI requires valid key arrays and distinct management and quota keys") end
        ' ${settings} > "$config_file"
      chmod 600 "$config_file"
      if ! cmp -s "$config_file" "$state/config.json"; then
        mv -f "$config_file" "$state/config.json"
      fi
    '';
  };
  start = pkgs.writeShellApplication {
    name = "cliproxyapi-start";
    text = ''
      ${lib.getExe writeConfig}
      exec ${lib.getExe pkgs.cliproxyapi} --config ${lib.escapeShellArg "${stateDirectory}/config.json"}
    '';
  };
in
{
  environment.systemPackages = [ pkgs.cliproxyapi ];
  wave.health.checks = {
    cliproxyapi = ''
      test "$(${lib.getExe pkgs.curl} --silent --output /dev/null --write-out '%{http_code}' \
        --max-time 5 http://127.0.0.1:8317/v1/models)" = 401
      test "$(${lib.getExe pkgs.curl} --silent --output /dev/null --write-out '%{http_code}' \
        --max-time 5 http://127.0.0.1:8317/v1/quota)" = 401
    '';
    # The site name from the Caddyfile, so a lost TLS policy or a certificate
    # that Caddy cannot renew fails the check instead of the gateway itself.
    tokens = ''
      test "$(${lib.getExe pkgs.curl} --silent --output /dev/null --write-out '%{http_code}' \
        --max-time 5 https://tokens.wave.exposed/v1/models)" = 401
    '';
  };
  launchd.daemons.cliproxyapi.serviceConfig = {
    ProgramArguments = [ (lib.getExe start) ];
    UserName = user;
    EnvironmentVariables = {
      HOME = home;
      MANAGEMENT_STATIC_PATH = toString managementStatic;
      CLIPROXYAPI_QUOTA_KEY_FILE = config.sops.secrets."cliproxyapi/quota-key".path;
    };
    WorkingDirectory = home;
    RunAtLoad = true;
    KeepAlive = true;
    ThrottleInterval = 10;
    Umask = 63;
    StandardOutPath = "${stateDirectory}/logs/server.log";
    StandardErrorPath = "${stateDirectory}/logs/error.log";
  };
  launchd.daemons.cliproxyapi-models.serviceConfig = {
    ProgramArguments = [ (lib.getExe writeConfig) ];
    UserName = user;
    EnvironmentVariables.HOME = home;
    StartInterval = 6 * 60 * 60;
    Umask = 63;
    StandardOutPath = "${stateDirectory}/logs/models.log";
    StandardErrorPath = "${stateDirectory}/logs/models.log";
  };
  system.activationScripts.preActivation.text = ''
    /usr/bin/install -d -m 0700 -o ${lib.escapeShellArg user} -g staff \
      ${lib.escapeShellArgs [
        stateDirectory
        "${stateDirectory}/auth"
        "${stateDirectory}/logs"
      ]}
    /usr/bin/touch ${
      lib.escapeShellArgs [
        "${stateDirectory}/logs/server.log"
        "${stateDirectory}/logs/error.log"
        "${stateDirectory}/logs/models.log"
      ]
    }
    /usr/sbin/chown ${lib.escapeShellArg "${user}:staff"} ${
      lib.escapeShellArgs [
        "${stateDirectory}/logs/server.log"
        "${stateDirectory}/logs/error.log"
        "${stateDirectory}/logs/models.log"
      ]
    }
    /bin/chmod 0600 ${
      lib.escapeShellArgs [
        "${stateDirectory}/logs/server.log"
        "${stateDirectory}/logs/error.log"
        "${stateDirectory}/logs/models.log"
      ]
    }
  '';
}
