{
  spotifast,
  installShellFiles,
  writeText,
}:

spotifast.overrideAttrs (old: {
  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ installShellFiles ];

  postInstall = (old.postInstall or "") + ''
    installShellCompletion --zsh ${writeText "_spotifast" ''
      #compdef spotifast

      local context state state_descr line
      typeset -A opt_args
      local -a commands=(
        'play-pause:Toggle playback' 'play:Start playback' 'pause:Pause playback'
        'next:Skip to the next track' 'previous:Return to the previous track'
        'seek:Seek by seconds' 'seek-to:Seek to a position in seconds'
        'volume:Set the volume' 'volume-up:Raise the volume' 'volume-down:Lower the volume'
        'mute:Toggle mute' 'shuffle:Toggle or set shuffle' 'repeat:Cycle or set repeat'
        'like:Toggle saving the current track' 'play-uri:Play a Spotify URI'
        'devices:List Spotify Connect devices' 'transfer:Move playback to a device'
        'now-playing:Print the current track' 'show:Show the window'
        'reload-themes:Reload local palette files' 'help:Show command help'
      )

      _arguments -C \
        '--device-name[Spotify Connect name for this session]:name:' \
        '(-v --verbose)'{-v,--verbose}'[Enable verbose logging]' \
        '(-h --help)'{-h,--help}'[Show help]' \
        '(-V --version)'{-V,--version}'[Show version]' \
        '1:command or Spotify link:->command' \
        '*::argument:->argument'

      case $state in
        command) _describe 'command' commands ;;
        argument)
          case $line[1] in
            shuffle) _arguments '1:state:(on off)' ;;
            repeat) _arguments '1:mode:(off context track)' ;;
            devices|now-playing) _arguments '--raw[Print the raw response]' ;;
            seek|seek-to) _arguments '1:seconds:' ;;
            volume|volume-up|volume-down) _arguments '1:percentage:' ;;
            play-uri) _arguments '1:Spotify URI:' ;;
            transfer) _arguments '1:device ID:' ;;
            help) _describe 'command' commands ;;
          esac
          ;;
      esac
    ''}
  '';
})
