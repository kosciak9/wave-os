{
  lib,
  stdenvNoCC,
  fetchurl,
  autoPatchelfHook,
  glibc,
  gh,
  installShellFiles,
  makeBinaryWrapper,
  writeText,
  versionCheckHook,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "drift-tui";
  version = "0.30.1";

  src = fetchurl {
    url = "https://github.com/tothalex/drift/releases/download/v${finalAttrs.version}/drift-linux-x86_64.tar.gz";
    hash = "sha256-QHjEie2KXNoFBBpTK2PDjCCSYh2Dx528H+UYKyQd3b0=";
  };

  sourceRoot = ".";
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;

  nativeBuildInputs = [
    installShellFiles
    makeBinaryWrapper
    autoPatchelfHook
  ];
  buildInputs = [ glibc ];

  installPhase = ''
    runHook preInstall
    install -Dm755 drift $out/bin/drift
    runHook postInstall
  '';

  postInstall = ''
    wrapProgram $out/bin/drift --prefix PATH : ${lib.makeBinPath [ gh ]}
    installShellCompletion --zsh ${writeText "_drift" ''
      #compdef drift

      local context state state_descr line
      typeset -A opt_args
      local -a commands=(
        'lang:Manage language plugins' 'update:Update drift' 'doctor:Check external CLIs'
        'help:Show command help'
      )

      _arguments -C \
        '(-b --base)'{-b,--base}'[Base branch]:branch:' \
        '--pr[Open a pull request]:number:' \
        '--no-viewed-sync[Keep viewed checks local]' \
        '--icons[Show Nerd Font icons]' \
        '--init-config[Write the default configuration]' \
        '(-h --help)'{-h,--help}'[Show help]' \
        '(-V --version)'{-V,--version}'[Show version]' \
        '1:repository or command:->entry' \
        '*::argument:->argument'

      case $state in
        entry)
          _alternative 'commands:command:_describe command commands' 'directories:repository:_directories'
          ;;
        argument)
          case $line[1] in
            lang)
              _arguments \
                '--rev[Grammar revision]:revision:' \
                '1:action:(install build list remove)' \
                '2:language or grammar URL:'
              ;;
            update) _arguments '--check[Only check for a newer release]' ;;
            help) _describe 'command' commands ;;
          esac
          ;;
      esac
    ''}
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [ versionCheckHook ];
  versionCheckProgram = "${placeholder "out"}/bin/drift";

  meta = {
    description = "Terminal UI for reviewing local changes and pull requests";
    homepage = "https://github.com/tothalex/drift";
    license = lib.licenses.mit;
    mainProgram = "drift";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
