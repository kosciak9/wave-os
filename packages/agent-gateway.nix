{
  lib,
  pkgs,
  apiKeyFile,
  baseUrlFile,
}:
package: client:
let
  program = package.meta.mainProgram;
  launcher = pkgs.writeShellScript "${program}-gateway" ''
    set -euo pipefail
    case "''${1:-}" in
      --version|-V|-v|--help|-h|--completions|completion|completions)
        exec ${lib.getExe package} "$@"
        ;;
    esac
    if [[ "''${WAVE_AGENT_DIRECT:-0}" == 1 ]]; then
      exec ${lib.getExe package} "$@"
    fi
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
