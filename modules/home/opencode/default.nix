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
    mcpApiKeyFile = osConfig.sops.secrets."mcp-gateway/api-key".path;
    apiKeyFile = osConfig.sops.secrets."cliproxyapi/api-key".path;
    baseUrlFile = osConfig.sops.secrets."cliproxyapi/base-url".path;
  };
  gatewayProvider = {
    env = [ "CLIPROXYAPI_API_KEY" ];
    package = "@opencode/ai/providers/openai-compatible/responses";
    settings = {
      baseURL = "{env:CLIPROXYAPI_BASE_URL}/v1";
      apiKey = "{env:CLIPROXYAPI_API_KEY}";
      # canonical = "openai" inherits OpenCode's WebSocket default; over it,
      # requests after an auto compaction fail with "No tool output found for
      # function call", apparently from CLIProxyAPI's socket history merging.
      transport = "http";
    };
  };
  cliConfig = lib.importJSON ./config/cli.json;
  mcpServers =
    lib.mapAttrs (_: command: {
      type = "local";
      inherit command;
    }) config.programs.agents.mcpServers
    // lib.listToAttrs (
      map (name: {
        name = "gw-${name}";
        value = {
          type = "remote";
          url = "${(import ../../mcp-gateway/settings.nix).baseURL}/${name}/mcp";
          headers.Authorization = "Bearer {env:MCP_GATEWAY_TOKEN}";
          oauth = false;
        };
      }) config.programs.agents.mcpGatewayServers
    );
  providers = {
    cliproxy = gatewayProvider // {
      name = "tokens @ wave";
      canonical = "openai";
      package = "@opencode/ai/providers/openai/responses";
      # Filled at launch from the gateway; see packages/agent-gateway.nix.
      models = {
        # Sol's delegation briefs degrade with longer context.
        "gpt-6.1-sol".limit = {
          context = 500000;
          input = 500000;
          output = 128000;
        };
      };
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
