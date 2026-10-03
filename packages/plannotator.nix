{
  stdenvNoCC,
  fetchurl,
  autoPatchelfHook,
  glibc,
  libgcc,
  lib,
}:

let
  version = "0.27.25";
  release =
    {
      "x86_64-linux" = {
        asset = "plannotator-linux-x64";
        hash = "sha256-ABr3dS+FQgJFifr8RK7DvifHMTOiw33zjwtZHCwUXdg=";
      };
      "aarch64-darwin" = {
        asset = "plannotator-darwin-arm64";
        hash = "sha256-JN5g+/jjvatRl88635zjgeioGPLVSyoFX2EpHHsiYOo=";
      };
    }
    .${stdenvNoCC.hostPlatform.system}
      or (throw "plannotator ${version} is unsupported on ${stdenvNoCC.hostPlatform.system}; supported systems are x86_64-linux and aarch64-darwin");
in
stdenvNoCC.mkDerivation {
  pname = "plannotator";
  inherit version;

  src = fetchurl {
    url = "https://github.com/backnotprop/plannotator/releases/download/v${version}/${release.asset}";
    inherit (release) hash;
  };

  nativeBuildInputs = lib.optionals stdenvNoCC.hostPlatform.isLinux [ autoPatchelfHook ];

  buildInputs = lib.optionals stdenvNoCC.hostPlatform.isLinux [
    glibc
    libgcc
  ];

  dontUnpack = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 "$src" "$out/bin/plannotator"
    runHook postInstall
  '';

  meta = {
    description = "Review and annotate coding plans from the terminal";
    homepage = "https://github.com/backnotprop/plannotator";
    license = with lib.licenses; [
      mit
      asl20
    ];
    mainProgram = "plannotator";
    platforms = [
      "x86_64-linux"
      "aarch64-darwin"
    ];
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
}
