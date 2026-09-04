{
  stdenvNoCC,
  fetchurl,
  autoPatchelfHook,
  glibc,
  libgcc,
  lib,
}:

let
  version = "0.27.12";
  release =
    {
      "x86_64-linux" = {
        asset = "plannotator-linux-x64";
        hash = "sha256-R5uicXyqLad+Lhiwo9YfQldHzl+mh7JBN4Qr1VV09m0=";
      };
      "aarch64-darwin" = {
        asset = "plannotator-darwin-arm64";
        hash = "sha256-8LLfK1XZXJaRKJHOmbK72skY3y1jVMSmZJ5V+ExdcCk=";
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
