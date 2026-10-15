{
  wl-clip-persist,
  installShellFiles,
  runCommand,
  symlinkJoin,
  writeText,
}:

let
  completions = runCommand "wl-clip-persist-completions" {
    nativeBuildInputs = [ installShellFiles ];
    postInstall = ''
      installShellCompletion --zsh ${writeText "_wl-clip-persist" ''
        #compdef wl-clip-persist

        _arguments \
          '(-c --clipboard)'{-c,--clipboard}'[Clipboard to persist]:clipboard:(regular primary both)' \
          '(-w --write-timeout)'{-w,--write-timeout}'[Clipboard write timeout]:milliseconds (1-2147483647):_numbers -l 1 -m 2147483647 -d 3000' \
          '(-e --ignore-event-on-error)'{-e,--ignore-event-on-error}'[Ignore selection events with errors]' \
          '(-l --selection-size-limit)'{-l,--selection-size-limit}'[Maximum selection size]:bytes:_numbers -l 1' \
          '(-f --all-mime-type-regex)'{-f,--all-mime-type-regex}'[Filter all offered MIME types]:regex:' \
          '--reconnect-tries[Maximum reconnect attempts]:attempts or inf:_alternative "unlimited:retry limit:(inf)" "numbers:attempts:_numbers -l 0 -d 0"' \
          '--reconnect-delay[Delay between reconnect attempts]:milliseconds (0-2147483647):_numbers -l 0 -m 2147483647 -d 100' \
          '--disable-timestamps[Disable log timestamps]' \
          '(-h --help)'{-h,--help}'[Show help]' \
          '(-V --version)'{-V,--version}'[Show version]'
      ''}
    '';
  } "runHook postInstall";
in
symlinkJoin {
  inherit (wl-clip-persist) pname version meta;
  paths = [
    completions
    wl-clip-persist
  ];
}
