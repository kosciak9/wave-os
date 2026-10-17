{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
  autoPatchelfHook,
  installShellFiles,
  makeWrapper,
  nodejs,
  versionCheckHook,
}:
let
  releases = {
    x86_64-linux = {
      target = "linux-x64";
      hash = "sha256-UAGPMGyOmF6hvQUSjXPxKKKfIp64p7Mqe7QpTObKejI=";
    };
    aarch64-darwin = {
      target = "darwin-arm64";
      hash = "sha256-VsaTo/5Nx0dTRZWBSzPOMrCqwLAcpfGK2spQPAnmYc4=";
    };
  };
  release = releases.${stdenvNoCC.hostPlatform.system};
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "happier";
  version = "0.2.16";

  src = fetchurl {
    url = "https://github.com/happier-dev/happier/releases/download/cli-stable/happier-v${finalAttrs.version}-${release.target}.tar.gz";
    inherit (release) hash;
  };

  nativeBuildInputs = [
    installShellFiles
    makeWrapper
  ]
  ++ lib.optional stdenvNoCC.hostPlatform.isLinux autoPatchelfHook;
  buildInputs = lib.optional stdenvNoCC.hostPlatform.isLinux stdenv.cc.cc.lib;

  dontConfigure = true;
  dontBuild = true;
  # The executable contains Bun's embedded application payload.
  dontStrip = true;

  postUnpack = lib.optionalString stdenvNoCC.hostPlatform.isLinux ''
    # NixOS uses glibc; the archive also ships unused Alpine prebuilds.
    rm -f "$sourceRoot"/node_modules/@homebridge/node-pty-prebuilt-multiarch/prebuilds/linux-x64/*.musl.node
    rm -r "$sourceRoot"/node_modules/sharp/node_modules/@img/*linuxmusl-x64
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/libexec/happier" "$out/bin"
    cp -r happier node_modules package-dist scripts tools "$out/libexec/happier/"
    makeWrapper "$out/libexec/happier/happier" "$out/bin/happier" \
      --prefix PATH : ${lib.makeBinPath [ nodejs ]} \
      --set HAPPIER_CLI_UPDATE_CHECK 0
    runHook postInstall
  '';

  postInstall = ''
    installShellCompletion --cmd happier --zsh ${./happier-completion.zsh}
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [ versionCheckHook ];

  meta = {
    description = "Encrypted remote companion for coding agents";
    homepage = "https://github.com/happier-dev/happier";
    license = lib.licenses.mit;
    mainProgram = "happier";
    platforms = builtins.attrNames releases;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
