{
  stdenvNoCC,
  fetchurl,
  gnutar,
  gzip,
  lib,
  makeBinaryWrapper,
}:

stdenvNoCC.mkDerivation {
  pname = "openclaw-llama-server";
  version = "b10809";

  src = fetchurl {
    url = "https://github.com/ggml-org/llama.cpp/releases/download/b10809/llama-b10809-bin-macos-arm64.tar.gz";
    hash = "sha256-fWkt+eHjhuYvHBK4Q5AyGAQebNdMlBWqOaftMXb56qI=";
  };

  nativeBuildInputs = [
    gnutar
    gzip
    makeBinaryWrapper
  ];

  dontUnpack = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    libexec="$out/libexec/openclaw-llama-server"
    mkdir -p "$libexec"
    tar -xzf "$src" -C "$libexec"

    llama_server=$(find "$libexec" -type f -name llama-server -perm -u+x -print -quit)
    test -n "$llama_server"
    runtime_dir=$(dirname "$llama_server")

    # These are the exact aliases consumed by the v2026.9.3 macOS manifest.
    # Official archives use the fully versioned names as their sources.
    for mapping in \
      libggml-rpc.0.23.0.dylib:libggml-rpc.0.dylib \
      libggml-rpc.0.23.0.dylib:libggml-rpc.dylib \
      libllama.0.4.0.dylib:libllama.0.dylib \
      libllama.0.4.0.dylib:libllama.dylib \
      libmtmd.0.4.0.dylib:libmtmd.0.dylib \
      libmtmd.0.4.0.dylib:libmtmd.dylib \
      libggml.0.23.0.dylib:libggml.0.dylib \
      libggml.0.23.0.dylib:libggml.dylib \
      libggml-base.0.23.0.dylib:libggml-base.0.dylib \
      libggml-base.0.23.0.dylib:libggml-base.dylib \
      libggml-blas.0.23.0.dylib:libggml-blas.0.dylib \
      libggml-blas.0.23.0.dylib:libggml-blas.dylib \
      libllama-common.0.4.0.dylib:libllama-common.0.dylib \
      libllama-common.0.4.0.dylib:libllama-common.dylib \
      libggml-cpu.0.23.0.dylib:libggml-cpu.0.dylib \
      libggml-cpu.0.23.0.dylib:libggml-cpu.dylib \
      libggml-metal.0.23.0.dylib:libggml-metal.0.dylib \
      libggml-metal.0.23.0.dylib:libggml-metal.dylib; do
      source="''${mapping%%:*}"
      alias="''${mapping#*:}"
      if [ -e "$runtime_dir/$source" ] && [ ! -e "$runtime_dir/$alias" ]; then
        ln -s "$source" "$runtime_dir/$alias"
      fi
    done

    mkdir -p "$out/bin"
    makeBinaryWrapper "$llama_server" "$out/bin/llama-server" \
      --set DYLD_LIBRARY_PATH "$runtime_dir"
    runHook postInstall
  '';

  meta = {
    description = "llama.cpp server for OpenClaw";
    homepage = "https://github.com/ggml-org/llama.cpp";
    license = lib.licenses.mit;
    mainProgram = "llama-server";
    platforms = [ "aarch64-darwin" ];
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
}
