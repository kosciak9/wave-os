{
  stdenvNoCC,
  fetchurl,
  makeBinaryWrapper,
  unzip,
  ripgrep,
  sysctl,
  lib,
}:

stdenvNoCC.mkDerivation {
  pname = "opencode";
  version = "1.18.3";

  src = fetchurl {
    url = "https://github.com/anomalyco/opencode/releases/download/v1.18.3/opencode-darwin-arm64.zip";
    hash = "sha256-lG9isVVji5ERRLe+9SDuSmRC9pYpeQeHNGO8o1JOQO8=";
  };

  nativeBuildInputs = [
    makeBinaryWrapper
    unzip
  ];

  dontUnpack = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    unzip -q $src
    install -Dm755 opencode $out/bin/.opencode-unwrapped
    makeBinaryWrapper $out/bin/.opencode-unwrapped $out/bin/opencode \
      --prefix PATH : ${lib.makeBinPath [ ripgrep sysctl ]} \
      --set OPENCODE_DISABLE_AUTOUPDATE true

    runHook postInstall
  '';

  meta = {
    description = "AI coding agent built for the terminal";
    homepage = "https://github.com/anomalyco/opencode";
    license = lib.licenses.mit;
    mainProgram = "opencode";
    platforms = [ "aarch64-darwin" ];
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
}
