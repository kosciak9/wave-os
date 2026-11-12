{
  stdenvNoCC,
  python3,
  makeWrapper,
  git,
  gh,
  lib,
}:
stdenvNoCC.mkDerivation {
  pname = "leak-scan";
  version = "1.0.0";
  dontUnpack = true;
  nativeBuildInputs = [ makeWrapper ];
  installPhase = ''
    runHook preInstall
    install -Dm755 ${./leak-scan.py} "$out/libexec/leak-scan.py"
    makeWrapper ${python3}/bin/python "$out/bin/leak-scan" \
      --add-flags "-I $out/libexec/leak-scan.py" \
      --prefix PATH : ${lib.makeBinPath [ git ]}
    # The gh overlay runs this in place of gh; it uses the user's git.
    makeWrapper ${python3}/bin/python "$out/libexec/gh/bin/gh" \
      --add-flags "-I $out/libexec/leak-scan.py gh" \
      --set LEAK_SCAN_GH ${lib.getExe gh}
    runHook postInstall
  '';
  meta = {
    description = "Block personal and company data in PR texts and commit messages";
    mainProgram = "leak-scan";
    platforms = lib.platforms.unix;
  };
}
