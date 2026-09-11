{
  stdenvNoCC,
  fetchurl,
  lib,
}:

stdenvNoCC.mkDerivation {
  pname = "openclaw-embeddinggemma";
  version = "2026.9.3";

  src = fetchurl {
    url = "https://huggingface.co/ggml-org/embeddinggemma-300m-qat-q8_0-GGUF/resolve/66f974f8cd48cc3b9c41c516b95508e75b4bee64/embeddinggemma-300m-qat-Q8_0.gguf";
    hash = "sha256-b6DAKpwwK+b5d1IdOZtN46RjEKTyYh7gBjdHiBtnP2c=";
  };

  dontUnpack = true;

  installPhase = ''
    runHook preInstall
    install -Dm644 "$src" "$out/share/openclaw/models/embeddinggemma-300m-qat-Q8_0.gguf"
    runHook postInstall
  '';

  meta = {
    description = "EmbeddingGemma 300M quantized GGUF model for OpenClaw";
    homepage = "https://huggingface.co/ggml-org/embeddinggemma-300m-qat-q8_0-GGUF";
    license = lib.licenses.unfree;
    platforms = [ "aarch64-darwin" ];
  };
}
