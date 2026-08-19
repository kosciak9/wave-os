{
  lib,
  sassc,
  stdenvNoCC,
  fetchFromGitHub,
}:

stdenvNoCC.mkDerivation {
  pname = "kanagawa-gtk-theme";
  version = "0-unstable-2025-10-23";

  src = fetchFromGitHub {
    owner = "Fausto-Korpsvart";
    repo = "Kanagawa-GKT-Theme";
    rev = "55ca4ba249eba21f861b9866b71ab41bb8930318";
    hash = "sha256-UdMoMx2DoovcxSp/zBZ3PRv/Qpj+prd0uPm1gmdak2E=";
  };

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/share/themes"
    name=Kanagawa PATH="${sassc}/bin:$PATH" bash themes/install.sh --dest "$out/share/themes" --tweaks outline
    for theme in "$out/share/themes"/*/; do
      [ -f "$theme/index.theme" ] || rm -rf "$theme"
    done

    runHook postInstall
  '';

  meta = {
    description = "Kanagawa GTK theme collection";
    homepage = "https://github.com/Fausto-Korpsvart/Kanagawa-GKT-Theme";
    license = lib.licenses.gpl3Only;
    platforms = lib.platforms.linux;
  };
}
