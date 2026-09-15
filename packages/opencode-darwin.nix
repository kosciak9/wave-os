{
  stdenv,
  autoPatchelfHook,
  fetchurl,
  glibc,
  makeBinaryWrapper,
  unzip,
  ripgrep,
  sysctl,
  plannotator,
  lib,
}:

let
  version = "1.18.31";
  release =
    if stdenv.hostPlatform.isDarwin then
      {
        asset = "opencode-darwin-arm64.zip";
        hash = "sha256-yvfzH6GuwjU+qFnU75q4JMYnPZQbAW6I1RGT+jAo004=";
      }
    else
      {
        asset = "opencode-linux-x64.tar.gz";
        hash = "sha256-6TEr517YA7dBX8Kuq9ofT+k4kSo5Zzdi3Aw4wOEeveQ=";
      };
in
stdenv.mkDerivation {
  pname = "opencode";
  inherit version;

  src = fetchurl {
    url = "https://github.com/anomalyco/opencode/releases/download/v${version}/${release.asset}";
    inherit (release) hash;
  };

  nativeBuildInputs = [
    makeBinaryWrapper
  ]
  ++ lib.optionals stdenv.hostPlatform.isDarwin [ unzip ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];

  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [ glibc ];

  dontUnpack = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    ${if stdenv.hostPlatform.isDarwin then "unzip -q $src" else "tar -xzf $src"}
    install -Dm755 opencode $out/bin/.opencode-unwrapped
    makeBinaryWrapper $out/bin/.opencode-unwrapped $out/bin/opencode \
      --prefix PATH : ${
        lib.makeBinPath [
          ripgrep
          sysctl
        ]
      } \
      --set PLANNOTATOR_BIN ${lib.getExe plannotator} \
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
      "x86_64-linux"
    ];
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
}
