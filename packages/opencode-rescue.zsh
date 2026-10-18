#compdef opencode-rescue

_arguments \
  '(--continue -c)'{--continue,-c}'[Continue the last session]' \
  '(--session -s)'{--session,-s}'[Session ID to continue or create]:session' \
  '--prompt[Prompt to use]:prompt' \
  '--auto[Auto-approve permissions that are not explicitly denied]' \
  '1:directory:_files -/'
