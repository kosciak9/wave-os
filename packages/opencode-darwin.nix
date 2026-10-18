{
  stdenv,
  autoPatchelfHook,
  fetchurl,
  glibc,
  makeBinaryWrapper,
  ripgrep,
  sysctl,
  lib,
}:

let
  version = "2.0.32";
  release =
    {
      "aarch64-darwin" = {
        target = "darwin-arm64";
        hash = "sha256-YtilJWZDspeEI/jpcb3IiW0sE8rAg4DRpd2UbM66Cas=";
      };
      "aarch64-linux" = {
        target = "linux-arm64";
        hash = "sha256-uEkjLsYdm2JNHEieVpWfU5Vm6xT45bKvXFTvI3EYz2M=";
      };
      "x86_64-linux" = {
        target = "linux-x64";
        hash = "sha256-ZKH0s4HC0u/BjI12ss45kUF3i0IbVMmLlL6OgIA2Btw=";
      };
    }
    .${stdenv.hostPlatform.system};
in
stdenv.mkDerivation {
  pname = "opencode";
  inherit version;

  src = fetchurl {
    url = "https://registry.npmjs.org/@opencode/cli-${release.target}/-/cli-${release.target}-${version}.tgz";
    inherit (release) hash;
  };

  nativeBuildInputs = [
    makeBinaryWrapper
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];

  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [ glibc ];

  dontUnpack = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    tar -xzf $src
    install -Dm755 package/bin/opencode $out/libexec/opencode
    mkdir -p $out/bin
    makeBinaryWrapper $out/libexec/opencode $out/bin/opencode \
      --argv0 opencode \
      --prefix PATH : ${
        lib.makeBinPath [
          ripgrep
          sysctl
        ]
      } \
      --set CAMOFOX_USER_ID opencode \
      --set OPENCODE_DISABLE_AUTOUPDATE true

    runHook postInstall
  '';

  meta = {
    description = "AI coding agent built for the terminal";
    homepage = "https://github.com/anomalyco/opencode";
    license = lib.licenses.mit;
    mainProgram = "opencode";
    platforms = [
      "aarch64-darwin"
      "aarch64-linux"
      "x86_64-linux"
    ];
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
}
