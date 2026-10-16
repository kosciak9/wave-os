#compdef earshot

_arguments -C \
  '--threads[CPU threads]:threads:' \
  '(-h --help)'{-h,--help}'[Show help]' \
  '1:command:(describe match rank find compare ab realness timeline sheet critique profile forge measure llm mcp doctor)' \
  '*:file:_files'
