{
  inputs,
  pkgs,
  lib,
  osConfig,
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
  codexSubscriptionModels = {
    "gpt-6.1-sol".name = "GPT-6.1 Sol";
    "gpt-6-astra".name = "GPT-6 Astra";
    "gpt-6-sol".name = "GPT-6 Sol";
    "gpt-6-luna".name = "GPT-6 Luna";
    "gpt-5.6-sol".name = "GPT-5.6 Sol";
    "gpt-5.6-terra".name = "GPT-5.6 Terra";
    "gpt-5.6-luna".name = "GPT-5.6 Luna";
  };
  providers = {
    cliproxy = gatewayProvider // {
      name = "CLIProxyAPI · Codex";
      canonical = "openai";
      package = "@opencode/ai/providers/openai/responses";
      models = lib.mapAttrs (
        _model: attrs: attrs // { capabilities.tools = true; }
      ) codexSubscriptionModels;
    };
    cliproxy-xai = gatewayProvider // {
      name = "CLIProxyAPI · Grok";
      canonical = "xai";
      models = {
        "grok-4.7" = {
          name = "Grok 4.7";
          capabilities.tools = true;
        };
      };
    };
    cliproxy-muse = gatewayProvider // {
      name = "CLIProxyAPI · Muse";
      models."muse-spark-1.3" = {
        name = "Muse Spark 1.3";
        capabilities.tools = true;
      };
    };
    cliproxy-zen-free = gatewayProvider // {
      name = "CLIProxyAPI · Zen Free";
      models =
        lib.genAttrs
          [
            "big-pickle"
            "cat-jam-free"
            "exo-free"
            "ling-3.0-flash-fin-free"
            "ling-3.1-flash-free"
            "longcat-2.5-preview-free"
            "mimo-v2.6-flash-free"
            "muse-spark-1.3-contributor-free"
            "nemotron-3-ultra-free"
            "nemotron-3.5-lightning-free"
            "space-bunny-free"
            "step-5-preview-free"
          ]
          (model: {
            modelID = "zen/${model}";
            capabilities.tools = true;
          });
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
        "providers": ${builtins.toJSON providers}
        }
      '';
      force = true;
    };
    "opencode/plugins/herdr-agent-state.js".source =
      inputs.herdr + "/src/integration/assets/opencode/herdr-agent-state.js";
    "opencode/herdr-tui-session.js".source =
      inputs.herdr + "/src/integration/assets/opencode/herdr-tui-session.js";
    "opencode/cli.json" = {
      source = ./config/cli.json;
      force = true;
    };
  };
}
