#compdef whatsapp-mcp
local -a common=(
  '--data-dir[State directory]:directory:_directories'
  '--log-level[Log level]:level:(debug info warn error)'
)
if (( CURRENT == 2 )); then
  _values command \
    'login[Link the account as a companion device]' \
    'serve[Serve the archive over MCP]' \
    'status[Show what is archived]' \
    'logout[Unlink the device and keep the archive]' \
    'version[Print the version]'
  return
fi
shift words
(( CURRENT-- ))
case $words[1] in
  login)
    _arguments -s $common \
      '--phone[Link with a pairing code for this phone number]:phone number:' \
      '--full-history[Ask the phone for its full history]' \
      '--history-days[With --full-history, limit to this many days]:days:' \
      '--sync-idle[Keep syncing until no history arrived for this long]:duration:'
    ;;
  serve)
    _arguments -s $common \
      '--transport[MCP transport]:transport:(stdio http)' \
      '--addr[Listen address for --transport http]:address:' \
      '--token[Bearer token for --transport http]:token:'
    ;;
  status | logout) _arguments -s $common ;;
esac
