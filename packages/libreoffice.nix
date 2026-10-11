{
  libreoffice,
  installShellFiles,
  writeText,
}:

libreoffice.overrideAttrs (old: {
  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ installShellFiles ];
  buildCommand = old.buildCommand + "\nrunHook postInstall\n";
  postInstall = (old.postInstall or "") + ''
    installShellCompletion --zsh ${writeText "_libreoffice" ''
      #compdef libreoffice soffice swriter scalc simpress sdraw smath sbase

      _arguments \
        '--help[Show help]' \
        '--version[Show version]' \
        '--writer[Open Writer]' \
        '--calc[Open Calc]' \
        '--impress[Open Impress]' \
        '--draw[Open Draw]' \
        '--math[Open Math]' \
        '--base[Open Base]' \
        '--view[Open read-only]' \
        '--show[Start a presentation]' \
        '--headless[Run without a graphical interface]' \
        '--nologo[Hide the splash screen]' \
        '--convert-to[Convert documents]:output format:' \
        '--outdir[Conversion output directory]:directory:_directories' \
        '*:document:_files'
    ''}
    installShellCompletion --zsh ${writeText "_unopkg" ''
      #compdef unopkg

      _arguments \
        '(-h --help)'{-h,--help}'[Show help]' \
        '(-V --version)'{-V,--version}'[Show version]' \
        '(-v --verbose)'{-v,--verbose}'[Show verbose output]' \
        '--shared[Manage shared extensions]' \
        '1:command:(add remove list validate reinstall gui)' \
        '*:extension:_files'
    ''}
  '';
})
