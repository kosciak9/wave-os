{
  wl-clip-persist,
  installShellFiles,
  writeText,
}:

wl-clip-persist.overrideAttrs (old: {
  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ installShellFiles ];

  postInstall = (old.postInstall or "") + ''
    installShellCompletion --zsh ${writeText "_wl-clip-persist" ''
      #compdef wl-clip-persist

      _arguments \
        '(-c --clipboard)'{-c,--clipboard}'[Clipboard to persist]:clipboard:(regular primary both)' \
        '(-w --write-timeout)'{-w,--write-timeout}'[Clipboard write timeout]:milliseconds:' \
        '(-e --ignore-event-on-error)'{-e,--ignore-event-on-error}'[Ignore selection events with errors]' \
        '(-l --selection-size-limit)'{-l,--selection-size-limit}'[Maximum selection size]:bytes:' \
        '(-f --all-mime-type-regex)'{-f,--all-mime-type-regex}'[Filter all offered MIME types]:regex:' \
        '--reconnect-tries[Maximum reconnect attempts]:attempts or inf:' \
        '--reconnect-delay[Delay between reconnect attempts]:milliseconds:' \
        '--disable-timestamps[Disable log timestamps]' \
        '(-h --help)'{-h,--help}'[Show help]' \
        '(-V --version)'{-V,--version}'[Show version]'
    ''}
  '';
})
