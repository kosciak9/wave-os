{
  stdenv,
  autoPatchelfHook,
  fetchurl,
  glibc,
  makeBinaryWrapper,
  ripgrep,
  sysctl,
  plannotator,
  lib,
}:

let
  version = "2.0.26";
  release =
    {
      "aarch64-darwin" = {
        target = "darwin-arm64";
        hash = "sha256-e03cpeY9OKHSrd02gnCEPCOuugCWE9/Q4zhS05uGEHY=";
      };
      "aarch64-linux" = {
        target = "linux-arm64";
        hash = "sha256-HXEX27MZaEVviVN7Vi+14g5I2envAyX8iEWr3abvSEI=";
      };
      "x86_64-linux" = {
        target = "linux-x64";
        hash = "sha256-ChFuAzoCgEdB1GRDN9ASvfWiSqwzo0wMllNNLVOWERk=";
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
      ${
        lib.optionalString (
          stdenv.hostPlatform.system != "aarch64-linux"
        ) "--set PLANNOTATOR_BIN ${lib.getExe plannotator}"
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
