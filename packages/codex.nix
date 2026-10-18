{
  prev,
  lib,
  stdenvNoCC,
  fetchurl,
  autoPatchelfHook,
  installShellFiles,
  makeBinaryWrapper,
  ncurses,
  versionCheckHook,
  ...
}:
let
  releases = {
    x86_64-linux = {
      target = "x86_64-unknown-linux-musl";
      hash = "sha256-WCZGxr8FYesN5UD3/IW5EhsAkagmvG6Wgwt/FyISIYI=";
    };
    aarch64-linux = {
      target = "aarch64-unknown-linux-musl";
      hash = "sha256-nY7PLRnT4YSHeYOQLWyF3kiziI3LcsOCqKDJdYRZJ/s=";
    };
    aarch64-darwin = {
      target = "aarch64-apple-darwin";
      hash = "sha256-sDRPwuQfFeAHEUflhpAIBHuP9L8sSoiXl107rj8QOzQ=";
    };
  };
  release = releases.${stdenvNoCC.hostPlatform.system};
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "codex";
  version = "0.163.0";

  src = fetchurl {
    url = "https://github.com/openai/codex/releases/download/rust-v${finalAttrs.version}/codex-package-${release.target}.tar.gz";
    inherit (release) hash;
  };

  sourceRoot = ".";
  strictDeps = true;
  nativeBuildInputs = [
    installShellFiles
    makeBinaryWrapper
  ]
  ++ lib.optional stdenvNoCC.hostPlatform.isLinux autoPatchelfHook;
  buildInputs = lib.optional stdenvNoCC.hostPlatform.isLinux ncurses;

  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    # Physical package-local files are required by daemon and voice validation.
    cp -r bin codex-package.json codex-path codex-resources "$out/"
    runHook postInstall
  '';

  postInstall = lib.optionalString (stdenvNoCC.buildPlatform.canExecute stdenvNoCC.hostPlatform) ''
    installShellCompletion --cmd codex \
      --bash <($out/bin/codex completion bash) \
      --fish <($out/bin/codex completion fish) \
      --zsh <($out/bin/codex completion zsh)
  '';

  postFixup = ''
    # Unlike a source-level default, this overrides TOML; later CLI overrides still win.
    wrapProgram "$out/bin/codex" --add-flags "-c features.daemon_auto_start=false"
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [ versionCheckHook ];

  meta = prev.codex.meta // {
    platforms = builtins.attrNames releases;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
