{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  installShellFiles,
  versionCheckHook,
}:
let
  releases = {
    x86_64-linux = {
      asset = "omp-linux-x64";
      hash = "sha256-/byBNghMmhBDlWkVeyr2IxLisNgByrVMc+iUdtp5jn4=";
    };
    aarch64-darwin = {
      asset = "omp-darwin-arm64";
      hash = "sha256-XlDfmHnekWXVxt9eSLtdA4c3JwATzYSeGJ2nd0+3Nos=";
    };
  };
  release = releases.${stdenv.hostPlatform.system};
in
stdenv.mkDerivation (finalAttrs: {
  pname = "omp";
  version = "18.12.5";

  src = fetchurl {
    url = "https://github.com/can1357/oh-my-pi/releases/download/v${finalAttrs.version}/${release.asset}";
    inherit (release) hash;
  };

  dontUnpack = true;
  strictDeps = true;
  nativeBuildInputs = [
    installShellFiles
  ]
  ++ lib.optional stdenv.hostPlatform.isLinux autoPatchelfHook;

  dontConfigure = true;
  dontBuild = true;
  # Bun keeps the bundled application inside the executable.
  dontStrip = true;
  # Patched in postInstall so the completions below can run the binary.
  dontAutoPatchelf = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 "$src" "$out/bin/omp"
    runHook postInstall
  '';

  postInstall =
    lib.optionalString stdenv.hostPlatform.isLinux ''
      autoPatchelf "$out"
    ''
    + lib.optionalString (stdenv.buildPlatform.canExecute stdenv.hostPlatform) ''
      export HOME="$(mktemp -d)"
      installShellCompletion --cmd omp \
        --bash <($out/bin/omp completions bash) \
        --fish <($out/bin/omp completions fish) \
        --zsh <($out/bin/omp completions zsh)
    '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [ versionCheckHook ];
  versionCheckKeepEnvironment = [ "HOME" ];

  meta = {
    description = "Coding agent for the terminal";
    homepage = "https://omp.sh";
    license = lib.licenses.mit;
    mainProgram = "omp";
    platforms = builtins.attrNames releases;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
