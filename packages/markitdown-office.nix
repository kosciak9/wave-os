{
  lib,
  stdenvNoCC,
  python3,
  makeWrapper,
  installShellFiles,
  writeText,
}:

let
  python = python3.withPackages (
    ps:
    [ ps.markitdown ]
    ++ ps.markitdown.optional-dependencies.docx
    ++ ps.markitdown.optional-dependencies.xlsx
    ++ ps.markitdown.optional-dependencies.pptx
  );
in
stdenvNoCC.mkDerivation {
  pname = "markitdown-office";
  inherit (python3.pkgs.markitdown) version;
  dontUnpack = true;

  nativeBuildInputs = [
    makeWrapper
    installShellFiles
  ];

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin"
    makeWrapper ${python}/bin/markitdown "$out/bin/markitdown"
    runHook postInstall
  '';

  postInstall = ''
    installShellCompletion --zsh ${writeText "_markitdown" ''
      #compdef markitdown

      _arguments \
        '(-h --help)'{-h,--help}'[Show help]' \
        '(-v --version)'{-v,--version}'[Show version]' \
        '(-o --output)'{-o,--output}'[Write output to a file]:output:_files' \
        '(-x --extension)'{-x,--extension}'[Hint the input extension]:extension:' \
        '(-m --mime-type)'{-m,--mime-type}'[Hint the input MIME type]:MIME type:' \
        '(-c --charset)'{-c,--charset}'[Hint the input charset]:charset:' \
        '(-d --use-docintel)'{-d,--use-docintel}'[Use Document Intelligence]' \
        '(--use-cu --use-content-understanding)'{--use-cu,--use-content-understanding}'[Use Content Understanding]' \
        '(-e --endpoint)'{-e,--endpoint}'[Document Intelligence endpoint]:endpoint:' \
        '--cu-endpoint[Content Understanding endpoint]:endpoint:' \
        '--cu-analyzer[Content Understanding analyzer]:analyzer:' \
        '--cu-file-types[Content Understanding file types]:file types:' \
        '(-p --use-plugins)'{-p,--use-plugins}'[Enable third-party plugins]' \
        '--list-plugins[List third-party plugins]' \
        '--keep-data-uris[Keep embedded data URIs]' \
        '1:document:_files'
    ''}
  '';

  meta = {
    description = "Offline Office document conversion to Markdown";
    homepage = "https://github.com/microsoft/markitdown";
    license = lib.licenses.mit;
    mainProgram = "markitdown";
    platforms = lib.platforms.linux;
  };
}
