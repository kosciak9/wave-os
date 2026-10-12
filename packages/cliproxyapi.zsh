#compdef cliproxyapi

if [[ $words[2] == discover ]]; then
  words=("${words[@]:1}")
  (( CURRENT-- ))
  _arguments -s \
    '(-h --help)'{-h,--help}'[Show help]' \
    '(-timeout --timeout)'{-timeout,--timeout}'[Discovery timeout in seconds]:seconds:' \
    '(-json --json)'{-json,--json}'[Output JSON]' \
    '(-service-type --service-type)'{-service-type,--service-type}'[DNS-SD service type]:service type:' \
    '(-config --config)'{-config,--config}'[Configuration file]:file:_files' \
    '*'{-include,--include}'[Comma-separated interfaces to scan]:interfaces:' \
    '*'{-exclude,--exclude}'[Comma-separated interfaces to skip]:interfaces:'
  return
fi

_arguments -s \
  '(-h --help)'{-h,--help}'[Show help]' \
  '(-config --config)'{-config,--config}'[Configuration file]:file:_files' \
  '(-codex-login --codex-login)'{-codex-login,--codex-login}'[Log in to Codex using OAuth]' \
  '(-codex-device-login --codex-device-login)'{-codex-device-login,--codex-device-login}'[Log in to Codex using device code flow]' \
  '(-claude-login --claude-login)'{-claude-login,--claude-login}'[Log in to Claude using OAuth]' \
  '(-antigravity-login --antigravity-login)'{-antigravity-login,--antigravity-login}'[Log in to Antigravity using OAuth]' \
  '(-kimi-login --kimi-login)'{-kimi-login,--kimi-login}'[Log in to Kimi.com using OAuth]' \
  '(-kimi-ai-login --kimi-ai-login)'{-kimi-ai-login,--kimi-ai-login}'[Log in to Kimi.ai using OAuth]' \
  '(-xai-login --xai-login)'{-xai-login,--xai-login}'[Log in to xAI using OAuth]' \
  '(-devin-login --devin-login)'{-devin-login,--devin-login}'[Log in to Devin using OAuth]' \
  '(-meta-login --meta-login)'{-meta-login,--meta-login}'[Log in to Meta using OAuth]' \
  '(-no-browser --no-browser)'{-no-browser,--no-browser}'[Do not open the OAuth browser automatically]' \
  '(-oauth-callback-port --oauth-callback-port)'{-oauth-callback-port,--oauth-callback-port}'[Override the OAuth callback port]:port:' \
  '(-vertex-import --vertex-import)'{-vertex-import,--vertex-import}'[Import a Vertex service account JSON file]:file:_files -g "*.json"' \
  '(-vertex-import-prefix --vertex-import-prefix)'{-vertex-import-prefix,--vertex-import-prefix}'[Vertex model namespace prefix]:prefix:' \
  '(-siwc-bind --siwc-bind)'{-siwc-bind,--siwc-bind}'[Bind Sign in with ChatGPT to a Codex credential file]:file:_files' \
  '(-tui --tui)'{-tui,--tui}'[Start the terminal management UI]' \
  '(-standalone --standalone)'{-standalone,--standalone}'[Start an embedded server in TUI mode]' \
  '(-management-base-url --management-base-url)'{-management-base-url,--management-base-url}'[Remote management API URL]:URL:' \
  '(-password --password)'{-password,--password}'[Management password]:password:' \
  '(-local-model --local-model)'{-local-model,--local-model}'[Use embedded model catalogs unless explicitly overridden]' \
  '(-home-jwt --home-jwt)'{-home-jwt,--home-jwt}'[Home control plane JWT]:JWT:' \
  '(-home-disable-cluster-discovery --home-disable-cluster-discovery)'{-home-disable-cluster-discovery,--home-disable-cluster-discovery}'[Disable Home cluster discovery]' \
  '(-discover --discover)'{-discover,--discover}'[Discover local AI gateways]' \
  '(-discover-timeout --discover-timeout)'{-discover-timeout,--discover-timeout}'[LAN discovery timeout in seconds]:seconds:' \
  '(-discover-json --discover-json)'{-discover-json,--discover-json}'[Output discovered gateways as JSON]' \
  '(-discover-service-type --discover-service-type)'{-discover-service-type,--discover-service-type}'[DNS-SD service type]:service type:' \
  '*'{-discover-include,--discover-include}'[Comma-separated interfaces to scan]:interfaces:' \
  '*'{-discover-exclude,--discover-exclude}'[Comma-separated interfaces to skip]:interfaces:' \
  '1:command:(discover)'
