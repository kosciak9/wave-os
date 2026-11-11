{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
  autoPatchelfHook,
  patchelf,
  makeWrapper,
  installShellFiles,
  versionCheckHook,
  vulkan-loader,
}:
let
  releases = {
    x86_64-linux = {
      target = "linux-x64";
      hash = "sha256-AUECUzXaM0dZzs2Ns0g+CXcvNgDKA2dGmFJOfZQpE2I=";
    };
    aarch64-darwin = {
      target = "darwin-arm64";
      hash = "sha256-fS64wGh7cMoDqdNUmDgYUtN5KYNYnoLR+xgxwI8LIwE=";
    };
  };
  release = releases.${stdenvNoCC.hostPlatform.system};
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "t3code-cli";
  version = "0.1.9";

  src = fetchurl {
    url = "https://github.com/pingdotgg/t3code/releases/download/v${finalAttrs.version}/t3-${finalAttrs.version}-${release.target}.tar.gz";
    inherit (release) hash;
  };

  nativeBuildInputs = [
    makeWrapper
    installShellFiles
  ]
  ++ lib.optionals stdenvNoCC.hostPlatform.isLinux [
    autoPatchelfHook
    patchelf
  ];
  # Voice transcription loads libggml-vulkan, which needs the Vulkan loader.
  buildInputs = lib.optionals stdenvNoCC.hostPlatform.isLinux [
    stdenv.cc.cc.lib
    vulkan-loader
  ];

  dontConfigure = true;
  dontBuild = true;
  # The executable contains Node's embedded application payload.
  dontStrip = true;

  postUnpack = lib.optionalString stdenvNoCC.hostPlatform.isLinux ''
    rm -r "$sourceRoot/node_modules/@ff-labs/fff-bin-linux-x64-musl" \
      "$sourceRoot/node_modules/@yuuang/ffi-rs-linux-x64-musl" \
      "$sourceRoot/node_modules/@koromix/koffi-linux-x64/musl_x64"
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
      # patchelf 0.19 corrupts Node's SEA payload if the interpreter is changed before the RPATH.
      patchelf --set-rpath ${lib.makeLibraryPath [ stdenv.cc.cc.lib ]} "$out/libexec/t3code/t3"
      autoPatchelf "$out/libexec/t3code"
    ''
    + lib.optionalString (stdenvNoCC.buildPlatform.canExecute stdenvNoCC.hostPlatform) ''
      HOME="$TMPDIR/t3-completions" "$out/bin/t3" --completions zsh > _t3
      installShellCompletion --zsh _t3
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
