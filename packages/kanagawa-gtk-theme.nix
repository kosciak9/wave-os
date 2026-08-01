{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
}:

stdenvNoCC.mkDerivation {
  pname = "kanagawa-gtk-theme";
  version = "0-unstable-2023-07-03";

  src = fetchFromGitHub {
    owner = "Fausto-Korpsvart";
    repo = "Kanagawa-GKT-Theme";
    rev = "35936a1e3bbd329339991b29725fc1f67f192c1e";
    hash = "sha256-BZRmjVas8q6zsYbXFk4bCk5Ec/3liy9PQ8fqFGHAXe0=";
  };

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/share/themes"
    for theme in themes/*/; do
      [ -f "$theme/index.theme" ] || continue
      themeDir="''${theme%/}"
      themeName="''${themeDir##*/}"
      mkdir -p "$out/share/themes/$themeName"
      cp "$theme/index.theme" "$out/share/themes/$themeName/"
      for gtkVersion in gtk-3.0 gtk-4.0; do
        if [ -d "$theme/$gtkVersion" ]; then
          cp -r "$theme/$gtkVersion" "$out/share/themes/$themeName/"
        fi
      done
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
