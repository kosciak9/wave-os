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
  goModels = import ./go-models.nix;
  zenModels = import ./zen-models.nix;
  opencodeHeaders = {
    User-Agent = "$User-Agent";
    x-opencode-client = "$x-opencode-client";
    x-opencode-project = "$x-opencode-project";
    x-opencode-session = "$x-opencode-session";
    x-opencode-session-id = "$x-opencode-session-id";
    x-opencode-parent-session-id = "$x-opencode-parent-session-id";
    x-opencode-request-id = "$x-opencode-request-id";
  };
  zenUpstream = name: models: {
    inherit name;
    prefix = "zen";
    base-url = "https://opencode.ai/inference/v1";
    headers = opencodeHeaders;
    models = map (model: { name = model; }) (builtins.attrNames models);
  };
  managementPanel = pkgs.fetchurl {
    name = "management.html";
    url = "https://github.com/router-for-me/Cli-Proxy-API-Management-Center/releases/download/v1.26.2/management.html";
    sha256 = "808cfd05ce5766a0f3854f8e095e5c5ea6e4313399f2df0d52b7a40352be29df";
  };
  managementStatic = pkgs.linkFarm "cliproxyapi-management-v1.26.2" [
    {
      name = "management.html";
      path = managementPanel;
    }
  ];
  goUpstream = name: models: {
    inherit name;
    prefix = "go";
    base-url = "https://opencode.ai/inference/go/v1";
    headers = {
      User-Agent = "$User-Agent";
      x-opencode-session = "$CPA-SESSION-ID";
    };
    models = map (model: { name = model; }) models;
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
          (goUpstream "opencode-go-responses" goModels.responses)
          (zenUpstream "opencode-zen-responses" zenModels.responses)
        ];
        # The Claude executor appends /v1/messages itself.
        claude = [
          (
            (goUpstream "opencode-go-messages" goModels.messages)
            // {
              base-url = "https://opencode.ai/inference/go";
            }
          )
        ];
        openai-compatibility = [
          (goUpstream "opencode-go-chat" goModels.chat)
          (zenUpstream "opencode-zen-chat" zenModels.chat)
        ];
      };
    }
  );
  start = pkgs.writeShellApplication {
    name = "cliproxyapi-start";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
    ];
    text = ''
      umask 077
      state=${lib.escapeShellArg stateDirectory}
      mkdir -p "$state/auth" "$state/logs"
      chmod 700 "$state" "$state/auth" "$state/logs"
      cd "$state"
      config_file=$(mktemp "$state/config.XXXXXX")
      trap 'rm -f "$config_file"' EXIT
      jq --slurpfile clients ${lib.escapeShellArg config.sops.secrets."cliproxyapi/client-keys".path} \
        --slurpfile go ${lib.escapeShellArg config.sops.secrets."cliproxyapi/opencode-go-keys".path} \
        --slurpfile zen ${lib.escapeShellArg config.sops.secrets."cliproxyapi/opencode-zen-keys".path} \
        --rawfile management ${lib.escapeShellArg config.sops.secrets."cliproxyapi/management-key".path} '
          def valid_keys: type == "array" and
            all(.[]; type == "string" and length > 0 and test("^[^\\r\\n]+$"));
          def with_keys($list):
            if ($list[0] | length) == 0 then .keys = []
            else .keys = ($list[0] | map({"api-key": .})) end;
          ($management | rtrimstr("\n")) as $management_key |
          if ($clients[0] | valid_keys and length > 0) and ($go[0] | valid_keys) and
            ($zen[0] | valid_keys) and
            ($management_key | length > 0 and test("^[^\\r\\n]+$")) and
            ($clients[0] | index($management_key) == null) then
            .access["api-keys"] = $clients[0] |
            .management["secret-key"] = $management_key |
            .["api-keys"] |= with_entries(.value |= map(
              if .name == "opencode-zen-responses" then
                with_keys($zen) | .keys |= map(. + {"disable-codex-cloaking": true})
              elif (.name | startswith("opencode-zen-")) then with_keys($zen)
              else with_keys($go) end))
          else error("CLIProxyAPI requires valid client/Go/Zen key arrays and a separate management key") end
        ' ${settings} > "$config_file"
      chmod 600 "$config_file"
      mv -f "$config_file" "$state/config.json"
      trap - EXIT
      exec ${lib.getExe pkgs.cliproxyapi} --config "$state/config.json"
    '';
  };
in
{
  environment.systemPackages = [ pkgs.cliproxyapi ];
  wave.health.checks.cliproxyapi = ''
    test "$(${lib.getExe pkgs.curl} --silent --output /dev/null --write-out '%{http_code}' \
      --max-time 5 http://127.0.0.1:8317/v1/models)" = 401
  '';
  launchd.daemons.cliproxyapi.serviceConfig = {
    ProgramArguments = [ (lib.getExe start) ];
    UserName = user;
    EnvironmentVariables = {
      HOME = home;
      MANAGEMENT_STATIC_PATH = toString managementStatic;
    };
    WorkingDirectory = home;
    RunAtLoad = true;
    KeepAlive = true;
    ThrottleInterval = 10;
    Umask = 63;
    StandardOutPath = "${stateDirectory}/logs/server.log";
    StandardErrorPath = "${stateDirectory}/logs/error.log";
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
      ]
    }
    /usr/sbin/chown ${lib.escapeShellArg "${user}:staff"} ${
      lib.escapeShellArgs [
        "${stateDirectory}/logs/server.log"
        "${stateDirectory}/logs/error.log"
      ]
    }
    /bin/chmod 0600 ${
      lib.escapeShellArgs [
        "${stateDirectory}/logs/server.log"
        "${stateDirectory}/logs/error.log"
      ]
    }
  '';
}
