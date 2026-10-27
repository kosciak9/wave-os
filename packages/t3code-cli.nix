{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
  installShellFiles,
  versionCheckHook,
}:
let
  releases = {
    x86_64-linux = {
      target = "linux-x64";
      hash = "sha256-Y80PBUfu9iu07OJ/p3m7+eK6hTHMaFQlaLqeeIONxoQ=";
    };
    aarch64-darwin = {
      target = "darwin-arm64";
      hash = "sha256-In99eeC4rvBQokMOQtlRAyZu+Kf3Iv6/6aKMstJmtHc=";
    };
  };
  release = releases.${stdenvNoCC.hostPlatform.system};
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "t3code-cli";
  version = "0.1.3";

  src = fetchurl {
    url = "https://github.com/pingdotgg/t3code/releases/download/v${finalAttrs.version}/t3-${finalAttrs.version}-${release.target}.tar.gz";
    inherit (release) hash;
  };

  nativeBuildInputs = [
    makeWrapper
    installShellFiles
  ]
  ++ lib.optional stdenvNoCC.hostPlatform.isLinux autoPatchelfHook;
  buildInputs = lib.optional stdenvNoCC.hostPlatform.isLinux stdenv.cc.cc.lib;

  dontConfigure = true;
  dontBuild = true;
  # The executable contains Node's embedded application payload.
  dontStrip = true;

  postUnpack = lib.optionalString stdenvNoCC.hostPlatform.isLinux ''
    rm -r "$sourceRoot/node_modules/@ff-labs/fff-bin-linux-x64-musl"
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/libexec/t3code" "$out/bin"
    cp -R . "$out/libexec/t3code/"
    makeWrapper "$out/libexec/t3code/t3" "$out/bin/t3" \
      --set T3CODE_DISABLE_AUTO_UPDATE 1 \
      --set T3CODE_TELEMETRY_ENABLED false
    runHook postInstall
  '';

  postInstall =
    lib.optionalString stdenvNoCC.hostPlatform.isLinux ''
      autoPatchelf "$out/libexec/t3code"
    ''
    + lib.optionalString (stdenvNoCC.buildPlatform.canExecute stdenvNoCC.hostPlatform) ''
      HOME="$TMPDIR/t3-completions" installShellCompletion --cmd t3 \
        --zsh <(HOME="$TMPDIR/t3-completions" "$out/bin/t3" --completions zsh)
    '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [ versionCheckHook ];
  versionCheckKeepEnvironment = [ "HOME" ];
  preVersionCheck = ''
    export HOME="$TMPDIR/t3-version-check"
    mkdir -p "$HOME"
  '';

  meta = {
    description = "T3 Code server and command-line interface";
    homepage = "https://github.com/pingdotgg/t3code";
    license = lib.licenses.mit;
    mainProgram = "t3";
    platforms = builtins.attrNames releases;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
