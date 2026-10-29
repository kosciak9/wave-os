{
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
  // lib.mapAttrs (_: command: {
    type = "local";
    inherit command;
  }) config.programs.agents.mcpServers;
  providers = {
    cliproxy = gatewayProvider // {
      name = "tokens @ wave";
      canonical = "openai";
      package = "@opencode/ai/providers/openai/responses";
      # Filled at launch from the gateway; see packages/agent-gateway.nix.
      models = { };
    };
  };
in

{
  home.packages = [
    (gatewayPackage pkgs.opencode "opencode")
    pkgs.opencode-rescue
    pkgs.camofox-browser-cli
  ];

  programs.zsh.generatedCompletions.opencode = "${pkgs.opencode}/bin/opencode --completions zsh";

  xdg.configFile = {
    # Safety Net requires interactive policy apply; keep the active policy user-owned.
    "cc-safety-net/policy-proposal.json".source = ./config/safety-net-policy.json;
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
    "opencode/cli.json" = {
      text = builtins.toJSON cliConfig;
      force = true;
    };
  };
}
