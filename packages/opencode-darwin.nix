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
  version = "2.2.0";
  release =
    {
      "aarch64-darwin" = {
        target = "darwin-arm64";
        hash = "sha256-wT4DNSXsdPohr49e8GKKpVU+OkAPV8eOkZUv79CKVog=";
      };
      "aarch64-linux" = {
        target = "linux-arm64";
        hash = "sha256-akBkPA3KOv+dN8h8JsDuADxGq7gQ4cbd3glP+/dGC4s=";
      };
      "x86_64-linux" = {
        target = "linux-x64";
        hash = "sha256-/jBGuGhy5iT2ImgFj0gBofHv/8GTEDqZiCOMiRuMoCg=";
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
