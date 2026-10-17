{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
  dpkg,
  electron_44,
  autoPatchelfHook,
  makeWrapper,
  wrapGAppsHook3,
  installShellFiles,
  gtk3,
  libsecret,
  libxkbcommon,
  claude-code,
  codex,
  opencode,
  git,
  gh,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "t3code-desktop";
  version = "0.1.0";

  src = fetchurl {
    url = "https://github.com/pingdotgg/t3code/releases/download/v${finalAttrs.version}/T3-Code-${finalAttrs.version}-amd64.deb";
    hash = "sha256-NZCmPC61vuIbcLIppFhjIu2CFArs2Mf+sJqoAXj4Y5w=";
  };

  nativeBuildInputs = [
    dpkg
    autoPatchelfHook
    makeWrapper
    wrapGAppsHook3
    installShellFiles
  ];
  buildInputs = [
    stdenv.cc.cc.lib
    gtk3
    libsecret
    libxkbcommon
  ];

  sourceRoot = "root";
  dontConfigure = true;
  dontBuild = true;
  dontWrapGApps = true;
  dontStrip = true;
  # Electron's existing RPATH also covers libraries loaded through dlopen.
  dontPatchELF = true;
  # The copied Electron is already patched; fix only upstream's native add-ons.
  dontAutoPatchelf = true;

  postUnpack = ''
    # NixOS uses glibc, not the additional Alpine prebuilds in the release.
    rm -r "$sourceRoot/opt/T3 Code (Beta)/resources/app.asar.unpacked/node_modules/@ff-labs/fff-bin-linux-x64-musl"
    rm -r "$sourceRoot/opt/T3 Code (Beta)/resources/app.asar.unpacked/node_modules/@yuuang/ffi-rs-linux-x64-musl"
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/libexec/t3code" "$out/bin"
    # Use nixpkgs' patched Electron while retaining a packaged app's resource layout.
    cp -rs ${electron_44.dist}/. "$out/libexec/t3code/"
    rm "$out/libexec/t3code/electron"
    cp ${electron_44.dist}/electron "$out/libexec/t3code/t3code"
    chmod u+w "$out/libexec/t3code/resources"
    rm -r "$out/libexec/t3code/resources"
    cp -R "opt/T3 Code (Beta)/resources" "$out/libexec/t3code/"
    cp -R usr/share "$out/"
    substituteInPlace "$out/share/applications/t3code.desktop" \
      --replace-fail '/opt/T3 Code (Beta)/t3code' "$out/bin/t3code-desktop"
    runHook postInstall
  '';

  postInstall = ''
    installShellCompletion --cmd t3code-desktop --zsh \
      <(printf '%s\n' '#compdef t3code-desktop' '_files')
  '';

  postFixup = ''
    autoPatchelf "$out/libexec/t3code/resources"
    makeWrapper "$out/libexec/t3code/t3code" "$out/bin/t3code-desktop" \
      "''${gappsWrapperArgs[@]}" \
      --set CHROME_DEVEL_SANDBOX ${electron_44}/libexec/electron/chrome-sandbox \
      --set T3CODE_DISABLE_AUTO_UPDATE 1 \
      --set T3CODE_TELEMETRY_ENABLED false \
      --prefix PATH : ${
        lib.makeBinPath [
          claude-code
          codex
          opencode
          git
          gh
        ]
      }
  '';

  meta = {
    description = "T3 Code desktop client for coding agents";
    homepage = "https://github.com/pingdotgg/t3code";
    license = lib.licenses.mit;
    mainProgram = "t3code-desktop";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
