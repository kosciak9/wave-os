{
  lib,
  pkgs,
  apiKeyFile,
  baseUrlFile,
}:
package: client:
let
  program = package.meta.mainProgram;
  # Writes an OpenCode config fragment with every model the gateway serves,
  # named from models.dev. OPENCODE_CONFIG merges it into the cliproxy provider.
  opencodeModels = pkgs.writeShellApplication {
    name = "opencode-gateway-models";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
    ];
    text = ''
      target=$1
      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT
      printf 'Authorization: Bearer %s\n' "$CLIPROXYAPI_API_KEY" |
        curl --fail --silent --show-error --max-time 5 --header @- \
          --output "$work/gateway.json" "$CLIPROXYAPI_BASE_URL/v1/models"
      curl --fail --silent --show-error --location --max-time 15 \
        --output "$work/catalog.json" https://models.dev/api.json
      jq --null-input --slurpfile gateway "$work/gateway.json" --slurpfile catalog "$work/catalog.json" '
        $catalog[0] as $catalog |
        def name($providers; $id): first($providers[] | $catalog[.].models[$id].name // empty) // $id;
        {openai: "OpenAI", xai: "xAI", meta: "Meta", anthropic: "Anthropic", google: "Google"} as $owners |
        [$gateway[0].data[] | select(.id | type == "string")] as $models |
        if ($models | length) == 0 then error("gateway lists no models") else
          {providers: {cliproxy: {models: ($models | map(
            (.id | split("/")) as $parts |
            {key: .id, value: ({capabilities: {tools: true}} + (
              if $parts[0] == "zen" and ($parts | length) == 2 then
                {name: "[Zen] \(name(["opencode", "opencode-go"]; $parts[1]))"}
              elif $parts[0] == "go" and ($parts | length) == 2 then
                {name: "[Go] \(name(["opencode-go", "opencode"]; $parts[1]))"}
              else
                {name: "[\($owners[.owned_by] // .owned_by // "Gateway")] \(name(["openai", "opencode"]; .id))"}
              end) + (
              # OpenAI subscription models keep the provider default package.
              if .owned_by == "openai" and ($parts | length) == 1 then {}
              else {package: "@opencode/ai/providers/openai-compatible/responses"} end))}
          ) | from_entries)}}}
        end
      ' > "$work/models.json"
      mkdir -p "$(dirname "$target")"
      mv -f "$work/models.json" "$target"
    '';
  };
  launcher = pkgs.writeShellScript "${program}-gateway" ''
    set -euo pipefail
    case "''${1:-}" in
      --version|-V|-v|--help|-h|--completions|completion|completions)
        exec ${lib.getExe package} "$@"
        ;;
    esac
    CLIPROXYAPI_API_KEY=$(< ${lib.escapeShellArg apiKeyFile})
    CLIPROXYAPI_BASE_URL=$(< ${lib.escapeShellArg baseUrlFile})
    export CLIPROXYAPI_API_KEY CLIPROXYAPI_BASE_URL
    CLIPROXYAPI_BASE_URL="''${CLIPROXYAPI_BASE_URL%/}"
    if [[ -z "$CLIPROXYAPI_API_KEY" || "$CLIPROXYAPI_BASE_URL" != https://* ]]; then
      printf 'Agent gateway requires a client key and HTTPS base URL in SOPS.\n' >&2
      exit 1
    fi
    ${lib.optionalString (client == "claude") ''
      export ANTHROPIC_BASE_URL="$CLIPROXYAPI_BASE_URL"
      export ANTHROPIC_AUTH_TOKEN="$CLIPROXYAPI_API_KEY"
      unset ANTHROPIC_API_KEY
      export CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1
    ''}
    ${lib.optionalString (client == "opencode") ''
      # The background service reads this when it starts, so newer models
      # appear after the service restarts.
      models="''${XDG_CACHE_HOME:-$HOME/.cache}/opencode/gateway-models.json"
      if [[ ! -s "$models" || -n "$(${pkgs.findutils}/bin/find "$models" -mmin +360)" ]]; then
        ${lib.getExe opencodeModels} "$models" ||
          printf 'Could not refresh gateway models for OpenCode.\n' >&2
      fi
      if [[ -s "$models" ]]; then
        export OPENCODE_CONFIG="$models"
      fi
    ''}
    ${lib.optionalString (client == "codex") ''
      base_url=$(${lib.getExe pkgs.jq} -n --arg url "$CLIPROXYAPI_BASE_URL/v1" '$url')
      catalog_url=$(${lib.getExe pkgs.jq} -n --arg url "$CLIPROXYAPI_BASE_URL/v1/models?client_version=${package.version}" '$url')
      exec ${lib.getExe package} \
        -c 'model_provider="cliproxy"' \
        -c 'model_providers.cliproxy.name="CLIProxyAPI"' \
        -c "model_providers.cliproxy.base_url=$base_url" \
        -c "model_providers.cliproxy.model_catalog_url=$catalog_url" \
        -c 'model_providers.cliproxy.env_key="CLIPROXYAPI_API_KEY"' \
        -c 'model_providers.cliproxy.wire_api="responses"' \
        -c 'model_providers.cliproxy.requires_openai_auth=false' \
        -c 'model_providers.cliproxy.supports_websockets=true' "$@"
    ''}
    exec ${lib.getExe package} "$@"
  '';
in
pkgs.runCommand "${package.pname}-${package.version}-gateway"
  {
    inherit (package)
      pname
      version
      passthru
      meta
      ;
  }
  ''
    mkdir -p $out/bin
    ln -s ${package}/bin/* $out/bin/
    rm $out/bin/${program}
    ln -s ${launcher} $out/bin/${program}
    if [ -d ${package}/share ]; then
      ln -s ${package}/share $out/share
    fi
  ''
