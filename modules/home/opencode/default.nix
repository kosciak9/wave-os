{
  inputs,
  pkgs,
  lib,
  osConfig,
  config,
  ...
}:

let
  gatewayPackage = import ../../../packages/agent-gateway.nix {
    inherit lib pkgs;
    apiKeyFile = osConfig.sops.secrets."cliproxyapi/api-key".path;
    baseUrlFile = osConfig.sops.secrets."cliproxyapi/base-url".path;
  };
  gatewayProvider = {
    env = [ "CLIPROXYAPI_API_KEY" ];
    package = "@opencode/ai/providers/openai-compatible/responses";
    settings = {
      baseURL = "{env:CLIPROXYAPI_BASE_URL}/v1";
      apiKey = "{env:CLIPROXYAPI_API_KEY}";
    };
  };
  zenModels = import ../../cliproxyapi/zen-models.nix;
  fugateStatus = import ../herdr/fugate-status.nix { inherit lib pkgs; };
  cliConfig = lib.importJSON ./config/cli.json;
  mcpServers = {
    context7 = {
      type = "local";
      command = [
        "sh"
        "-c"
        "if CONTEXT7_API_KEY=$(pass show context7.com/api-key 2>/dev/null); then export CONTEXT7_API_KEY; else unset CONTEXT7_API_KEY; fi; exec npx -y @upstash/context7-mcp@4.4.1"
      ];
    };
    parallel-search = {
      type = "remote";
      url = "https://search.parallel.ai/mcp";
      oauth = false;
    };
  }
  // lib.optionalAttrs (config.programs.agents.cua.enable or pkgs.stdenv.hostPlatform.isLinux) {
    cua-driver = {
      type = "local";
      command = [
        (lib.getExe (pkgs.callPackage ../../../packages/cua-driver.nix { }))
        "mcp"
        "--socket"
        "${config.xdg.cacheHome}/cua-driver/cua-driver.sock"
      ];
    };
  };
  codexSubscriptionModels = {
    "gpt-6.1-sol".name = "[OpenAI] GPT 6.1 Sol";
    "gpt-6-astra".name = "[OpenAI] GPT 6 Astra";
    "gpt-6-sol".name = "[OpenAI] GPT 6 Sol";
    "gpt-6-luna".name = "[OpenAI] GPT 6 Luna";
    "gpt-5.6-sol".name = "[OpenAI] GPT 5.6 Sol";
    "gpt-5.6-terra".name = "[OpenAI] GPT 5.6 Terra";
    "gpt-5.6-luna".name = "[OpenAI] GPT 5.6 Luna";
  };
  providers = {
    cliproxy = gatewayProvider // {
      name = "tokens @ wave";
      canonical = "openai";
      package = "@opencode/ai/providers/openai/responses";
      models =
        (lib.mapAttrs (_model: attrs: attrs // { capabilities.tools = true; }) codexSubscriptionModels)
        // {
          "grok-4.7" = {
            name = "[xAI] Grok 4.7";
            package = "@opencode/ai/providers/openai-compatible/responses";
            capabilities.tools = true;
          };
          "muse-spark-1.3" = {
            name = "[Meta] Muse Spark 1.3";
            package = "@opencode/ai/providers/openai-compatible/responses";
            capabilities.tools = true;
          };
        }
        // lib.mapAttrs (model: name: {
          name = "[Zen] ${name}";
          modelID = "zen/${model}";
          package = "@opencode/ai/providers/openai-compatible/responses";
          capabilities.tools = true;
        }) (zenModels.chat // zenModels.responses);
    };
  };
in

{
  home.packages = [
    (gatewayPackage pkgs.opencode "opencode")
    pkgs.camofox-browser-cli
  ];

  programs.zsh.generatedCompletions.opencode = "${pkgs.opencode}/bin/opencode --completions zsh";

  xdg.configFile = {
    "opencode/commands" = {
      source = ./config/commands;
      force = true;
      recursive = true;
    };
    "opencode/opencode.jsonc" = {
      text = lib.removeSuffix "}\n" (builtins.readFile ./config/opencode.jsonc) + ''
        "providers": ${builtins.toJSON providers},
        "mcp": ${builtins.toJSON { servers = mcpServers; }}
        }
      '';
      force = true;
    };
    "opencode/plugins/herdr-agent-state.js".source =
      inputs.herdr + "/src/integration/assets/opencode/herdr-agent-state.js";
    "opencode/herdr-tui-session.js".source =
      inputs.herdr + "/src/integration/assets/opencode/herdr-tui-session.js";
    "opencode/cli.json" = {
      text = builtins.toJSON (
        cliConfig // { plugins = cliConfig.plugins ++ [ "${fugateStatus.opencodePlugin}" ]; }
      );
      force = true;
    };
  };
}
