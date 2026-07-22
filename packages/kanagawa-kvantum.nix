{ stdenvNoCC, src }:

stdenvNoCC.mkDerivation {
  pname = "kanagawa-kvantum";
  version = "0-unstable-2026-02-10";
  inherit src;
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/share/Kvantum"
    cp -r Kanagawa "$out/share/Kvantum/"
    runHook postInstall
  '';
}
