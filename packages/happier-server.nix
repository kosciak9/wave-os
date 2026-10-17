{
  lib,
  stdenvNoCC,
  fetchurl,
  makeWrapper,
  installShellFiles,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "happier-server";
  version = "0.2.16";

  src = fetchurl {
    url = "https://github.com/happier-dev/happier/releases/download/server-stable/happier-server-v${finalAttrs.version}-darwin-arm64.tar.gz";
    hash = "sha256-JKa8LErF00qWm35RZAkyh8tKSfn8v7J4qSdfVJgnv+E=";
  };

  nativeBuildInputs = [
    makeWrapper
    installShellFiles
  ];
  dontConfigure = true;
  dontBuild = true;
  # Preserve signed Mach-O executables and Bun's embedded application payload.
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/libexec/happier-server" "$out/bin"
    cp -R . "$out/libexec/happier-server/"
    makeWrapper "$out/libexec/happier-server/happier-server" "$out/bin/happier-server" \
      --set-default HAPPIER_SERVER_UI_DIR "$out/libexec/happier-server/ui-web/current"
    runHook postInstall
  '';

  postInstall = ''
    installShellCompletion --cmd happier-server --zsh \
      <(printf '%s\n' '#compdef happier-server' '_files')
  '';

  meta = {
    description = "Self-hosted Happier relay with bundled web client";
    homepage = "https://github.com/happier-dev/happier";
    license = lib.licenses.mit;
    mainProgram = "happier-server";
    platforms = [ "aarch64-darwin" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
