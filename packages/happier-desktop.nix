{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
  dpkg,
  autoPatchelfHook,
  wrapGAppsHook3,
  makeWrapper,
  installShellFiles,
  glib-networking,
  libayatana-appindicator,
  webkitgtk_4_1,
  happier,
  xdg-utils,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "happier-desktop";
  version = "0.2.17";

  src = fetchurl {
    url = "https://github.com/happier-dev/happier/releases/download/ui-desktop-stable/happier-ui-desktop-linux-x86_64-v${finalAttrs.version}.deb";
    hash = "sha256-bR4t1y2cJ5Zb6ZqYn4Mnd6Qljyz12IdvR5UF5I1z2Oo=";
  };

  nativeBuildInputs = [
    dpkg
    autoPatchelfHook
    wrapGAppsHook3
    makeWrapper
    installShellFiles
  ];
  buildInputs = [
    stdenv.cc.cc.lib
    glib-networking
    libayatana-appindicator
    webkitgtk_4_1
  ];

  sourceRoot = "root";
  dontConfigure = true;
  dontBuild = true;
  dontWrapGApps = true;
  # The bundled setup helper contains Bun's embedded application payload.
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin" "$out/libexec/happier-desktop"
    cp usr/bin/app "$out/libexec/happier-desktop/app"
    # Keep the patched helper beside the executable, where upstream also searches.
    gzip -dc usr/lib/Happier/binaries/hsetup-x86_64-unknown-linux-gnu.gz \
      > "$out/libexec/happier-desktop/hsetup"
    chmod +x "$out/libexec/happier-desktop/hsetup"
    cp -r usr/share "$out/"
    for icon in "$out"/share/icons/hicolor/*/apps/app.png; do
      mv "$icon" "''${icon%app.png}happier-desktop.png"
    done
    substituteInPlace "$out/share/applications/Happier.desktop" \
      --replace-fail 'Exec=app' "Exec=$out/bin/happier-desktop %u" \
      --replace-fail 'Icon=app' 'Icon=happier-desktop' \
      --replace-fail 'Comment=A Tauri App' 'Comment=Remote companion for coding agents' \
      --replace-fail 'Categories=' 'Categories=Development;'
    runHook postInstall
  '';

  postInstall = ''
    installShellCompletion --cmd happier-desktop --zsh \
      <(printf '%s\n' '#compdef happier-desktop' '_urls')
  '';

  postFixup = ''
    makeWrapper "$out/libexec/happier-desktop/app" "$out/bin/happier-desktop" \
      "''${gappsWrapperArgs[@]}" \
      --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ libayatana-appindicator ]} \
      --suffix PATH : ${
        lib.makeBinPath [
          happier
          xdg-utils
        ]
      }
  '';

  meta = {
    description = "Desktop companion for coding agents";
    homepage = "https://github.com/happier-dev/happier";
    license = lib.licenses.mit;
    mainProgram = "happier-desktop";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
