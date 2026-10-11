{
  lib,
  stdenvNoCC,
  fetchurl,
  autoPatchelfHook,
  dpkg,
  wrapGAppsHook3,
  glib-networking,
  gtk3,
  webkitgtk_4_1,
  libayatana-appindicator,
  openssl,
  libgcc,
  installShellFiles,
  writeText,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "reviewly";
  version = "0.1.8";

  src = fetchurl {
    url = "https://github.com/volnei/reviewly/releases/download/v${finalAttrs.version}/Reviewly-${finalAttrs.version}-linux.deb";
    hash = "sha256-vWttkkEuGjLm00Pargzt24w49z9ei1bvcsTkj4tUCUk=";
  };

  sourceRoot = "root";
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  strictDeps = true;

  nativeBuildInputs = [
    installShellFiles
    autoPatchelfHook
    dpkg
    wrapGAppsHook3
  ];

  buildInputs = [
    glib-networking
    gtk3
    webkitgtk_4_1
    libayatana-appindicator
    openssl
    libgcc
  ];
  runtimeDependencies = [
    (lib.getLib libayatana-appindicator)
  ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -r usr/bin usr/share $out/
    substituteInPlace $out/share/applications/Reviewly.desktop \
      --replace-fail 'Exec=reviewly' "Exec=$out/bin/reviewly" \
      --replace-fail 'Categories=' 'Categories=Development;'
    runHook postInstall
  '';

  postInstall = ''
    installShellCompletion --zsh ${writeText "_reviewly" ''
      #compdef reviewly

      _message 'Reviewly desktop application (no command-line options)'
    ''}
  '';

  meta = {
    description = "Local-first desktop application for reviewing GitHub pull requests";
    homepage = "https://github.com/volnei/reviewly";
    license = lib.licenses.gpl3Plus;
    mainProgram = "reviewly";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
