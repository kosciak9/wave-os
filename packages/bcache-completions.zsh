#compdef bcache make-bcache bcache-super-show

case "${words[1]:t}" in
  bcache)
    if (( CURRENT == 2 )); then
      local -a commands=(
        'show:Show bcache devices'
        'tree:Show active bcache devices'
        'make:Format a cache or backing device'
        'register:Register a device'
        'unregister:Unregister a device'
        'attach:Attach a backing device to a cache'
        'detach:Flush and detach a backing device'
        'set-cachemode:Set the backing device cache mode'
        'set-label:Set the backing device label'
      )
      _describe 'command' commands
    elif [[ $words[2] == make ]]; then
      words=(make-bcache "${words[@]:2}")
      (( CURRENT-- ))
      _bcache
    elif [[ $words[2] == set-cachemode && CURRENT -eq 4 ]]; then
      compadd writethrough writeback writearound none
    else
      _files
    fi
    ;;
  make-bcache)
    _arguments -s \
      '(-C --cache)'{-C,--cache}'[Format a cache device]' \
      '(-B --bdev)'{-B,--bdev}'[Format a backing device]' \
      '(-b --bucket)'{-b,--bucket}'[Set bucket size]:size:' \
      '(-w --block)'{-w,--block}'[Set block size]:size:' \
      '(-o --data-offset)'{-o,--data-offset}'[Set data offset in sectors]:sectors:' \
      '--cset-uuid[Set cache set UUID]:UUID:' \
      '--writeback[Enable writeback mode]' \
      '--discard[Enable discards]' \
      '--force[Reformat a running bcache device]' \
      '(-l --label)'{-l,--label}'[Set device label]:label:' \
      '--cache_replacement_policy=[Set replacement policy]:policy:(lru fifo)' \
      '(-h --help)'{-h,--help}'[Show help]' \
      '*:device:_files'
    ;;
  bcache-super-show)
    _arguments '-f[Show a superblock even if validation fails]' '1:device:_files'
    ;;
esac
