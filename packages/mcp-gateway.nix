{
  lib,
  writeShellApplication,
  runCommand,
  coreutils,
  jq,
  mcp-proxy,
  installShellFiles,
  apiKeyFile,
  proxySettings ? import ../modules/mcp-gateway/settings.nix,
}:
let
  script = writeShellApplication {
    name = "mcp-gateway";
    runtimeInputs = [
      coreutils
      jq
    ];
    text = ''
      umask 077
      servers="$HOME/.config/mcp-gateway/servers.json"
      state="$HOME/.local/state/mcp-gateway"
      install -d -m 0700 "$state"
      config=$(mktemp "$state/config.XXXXXXXX.json")
      trap 'rm -f "$config"' EXIT
      jq --null-input --rawfile token ${lib.escapeShellArg apiKeyFile} \
        --slurpfile servers "$servers" \
        --argjson proxy ${lib.escapeShellArg (builtins.toJSON proxySettings)} '
        ($token | rtrimstr("\n")) as $token |
        if ($token | length) == 0 then error("MCP gateway key is empty")
        elif ($servers | length) != 1 or ($servers[0] | type) != "object" then
          error("servers.json must contain one object of MCP server entries")
        else {mcpProxy: ($proxy + {options: {authTokens: [$token]}}), mcpServers: $servers[0]} end
      ' > "$config"
      mv -f "$config" "$state/config.json"
      # The key and servers.json are literal; expansion would rewrite any `$` in them.
      exec ${lib.getExe mcp-proxy} -config "$state/config.json" -expand-env=false "$@"
    '';
  };
in
runCommand "mcp-gateway"
  {
    nativeBuildInputs = [ installShellFiles ];
    meta.mainProgram = "mcp-gateway";
  }
  ''
    install -Dm755 ${lib.getExe script} $out/bin/mcp-gateway
    installShellCompletion --cmd mcp-gateway --zsh ${./mcp-gateway.zsh}
  ''
