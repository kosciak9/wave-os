{
  spotifast,
  installShellFiles,
  jq,
  runCommand,
  symlinkJoin,
  writeText,
}:

let
  completions = runCommand "spotifast-completions" {
    nativeBuildInputs = [ installShellFiles ];
    postInstall = ''
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
          'play-search:Search Spotify and play the best match'
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
          '*::argument:->argument' && return

        case $state in
          command) _describe 'command' commands ;;
          argument)
            case $line[1] in
              shuffle) _arguments '(-h --help)'{-h,--help}'[Show help]' '1:state:(on off)' ;;
              repeat) _arguments '(-h --help)'{-h,--help}'[Show help]' '1:mode:(off context track)' ;;
              devices|now-playing) _arguments '(-h --help)'{-h,--help}'[Show help]' '--raw[Print the raw response]' ;;
              seek) _arguments '(-h --help)'{-h,--help}'[Show help]' '1:seconds (negative seeks backwards):_numbers -N' ;;
              seek-to) _arguments '(-h --help)'{-h,--help}'[Show help]' '1:seconds from start:_numbers -l 0' ;;
              volume) _arguments '(-h --help)'{-h,--help}'[Show help]' '1:percentage (0-100):_numbers -l 0 -m 100' ;;
              volume-up|volume-down) _arguments '(-h --help)'{-h,--help}'[Show help]' '1:percentage (1-100, default 10):_numbers -l 1 -m 100 -d 10' ;;
              play-uri) _arguments '(-h --help)'{-h,--help}'[Show help]' '1:Spotify URI:' ;;
              play-search)
                _arguments \
                  '(-h --help)'{-h,--help}'[Show help]' \
                  '--kind[What to search for]:kind:(track album artist playlist)' \
                  '*:search terms:'
                ;;
              transfer)
                _arguments '(-h --help)'{-h,--help}'[Show help]' '1:device ID:->device'
                if [[ $state == device ]]; then
                  local -a devices
                  devices=("''${(@f)$(spotifast devices --raw 2>/dev/null | ${jq}/bin/jq -r '
                    .[] | select(.id | type == "string" and length > 0)
                    | (.id | gsub(":"; "\\:")) + ":" + .name + " (" + .kind + ")"
                  ' 2>/dev/null)}")
                  _describe 'device' devices
                fi
                ;;
              help) _describe 'command' commands ;;
              *) _arguments '(-h --help)'{-h,--help}'[Show help]' ;;
            esac
            ;;
        esac
      ''}
    '';
  } "runHook postInstall";
in
symlinkJoin {
  inherit (spotifast) pname version meta;
  paths = [
    completions
    spotifast
  ];
}
