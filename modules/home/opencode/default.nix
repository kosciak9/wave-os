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
  goModels = import ../../cliproxyapi/go-models.nix;
  gatewayProvider = {
    env = [ "CLIPROXYAPI_API_KEY" ];
    package = "@opencode/ai/providers/openai-compatible/responses";
    settings = {
      baseURL = "{env:CLIPROXYAPI_BASE_URL}/v1";
      apiKey = "{env:CLIPROXYAPI_API_KEY}";
    };
  };
  providers = {
    cliproxy = gatewayProvider // {
      name = "CLIProxyAPI · Codex";
      canonical = "openai";
      package = "@opencode/ai/providers/openai/responses";
    };
    cliproxy-xai = gatewayProvider // {
      name = "CLIProxyAPI · Grok";
      canonical = "xai";
    };
    cliproxy-muse = gatewayProvider // {
      name = "CLIProxyAPI · Muse";
      models."muse-spark-1.3" = {
        name = "Muse Spark 1.3";
        capabilities.tools = true;
      };
    };
    cliproxy-go = gatewayProvider // {
      name = "CLIProxyAPI · OpenCode Go";
      canonical = "opencode-go";
      models =
        lib.genAttrs
          (lib.filter (model: !(lib.hasPrefix "claude-" model)) (
            goModels.responses ++ goModels.messages ++ goModels.chat
          ))
          (model: {
            modelID = "go/${model}";
          })
        // {
          "claude-haiku-5-5".disabled = true;
        };
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
