{
  stdenvNoCC,
  fetchurl,
  lib,
}:

stdenvNoCC.mkDerivation {
  pname = "openclaw-whisper-model";
  version = "2026.9.4";

  src = fetchurl {
    url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/98aa99a0a9db05ae2342309f5096248665f7cba3/ggml-large-v3-turbo-q5_0.bin";
    hash = "sha256-OUIhcJzVrR9AxG5gMcphvOiJMebgiMGIKUxtWlX/p+I=";
  };

  dontUnpack = true;

  installPhase = ''
    runHook preInstall
    install -Dm644 "$src" "$out/share/openclaw/models/ggml-large-v3-turbo-q5_0.bin"
    runHook postInstall
  '';

  meta = {
    description = "Whisper large-v3-turbo quantized speech recognition model for OpenClaw";
    homepage = "https://huggingface.co/ggerganov/whisper.cpp";
    license = lib.licenses.mit;
    platforms = [ "aarch64-darwin" ];
  };
}
