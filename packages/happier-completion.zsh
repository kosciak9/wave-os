#compdef happier

local context state state_descr
local -a commands line
local -A opt_args
commands=(
  'auth:Manage authentication'
  'claude:Start Claude Code'
  'codex:Start Codex'
  'opencode:Start OpenCode'
  'gemini:Start Gemini'
  'daemon:Manage the local daemon'
  'doctor:Run diagnostics'
  'status:Show system status'
  'session:Manage sessions'
  'resume:Resume a session'
  'server:Manage relay servers'
  'service:Manage automatic startup'
  'setup:Connect this computer'
  'profiles:Manage backend profiles'
  'connect:Connect AI vendor accounts'
  'notify:Send a push notification'
  'mcp:Manage MCP integration'
)

_arguments -C \
  '(-h --help)'{-h,--help}'[Show help]' \
  '(-v --version)'{-v,--version}'[Show version]' \
  '--server[Select server]:server:' \
  '--server-url[Relay URL]:URL:_urls' \
  '--webapp-url[Web app URL]:URL:_urls' \
  '1:command:->command' \
  '*:argument:->argument'

case $state in
  command) _describe 'command' commands ;;
  argument)
    case $line[1] in
      auth) compadd login logout status ;;
      daemon) compadd start stop status ;;
      *) _files ;;
    esac
    ;;
esac
