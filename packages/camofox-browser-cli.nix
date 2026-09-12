{
  stdenvNoCC,
  python3,
  makeWrapper,
  lib,
}:
stdenvNoCC.mkDerivation {
  pname = "camofox-browser-cli";
  version = "1.0.0";
  dontUnpack = true;
  nativeBuildInputs = [ makeWrapper ];
  installPhase = ''
    install -Dm755 ${./camofox-browser-cli.py} "$out/libexec/camofox-browser-cli.py"
    makeWrapper ${python3}/bin/python "$out/bin/camofox" \
      --add-flags "$out/libexec/camofox-browser-cli.py"
  '';
  meta = {
    description = "Dependency-free REST CLI for Camofox browser";
    mainProgram = "camofox";
    platforms = lib.platforms.unix;
  };
}
