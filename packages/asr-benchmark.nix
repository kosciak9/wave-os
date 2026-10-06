{
  lib,
  cctools,
  fetchurl,
  python312,
  runCommand,
  stdenvNoCC,
  makeWrapper,
  ffmpeg,
  whisper-cpp,
}:
let
  py = python312.pkgs;
  mlxMetal = py.buildPythonPackage {
    pname = "mlx-metal";
    version = "0.32.3";
    format = "wheel";
    src = fetchurl {
      url = "https://files.pythonhosted.org/packages/ee/38/cb985ca86979ca6f954a2a45eb6e3f9b787c5d55227564a04f87953b3d56/mlx_metal-0.32.3-py3-none-macosx_26_0_arm64.whl";
      sha256 = "34ae9b83ad2f0ccdd3e5d48ec35176e7119f57069eef187122916dc941a4ae1f";
    };
    meta = {
      description = "MLX 0.32.3 Metal kernels";
      license = lib.licenses.mit;
      platforms = [ "aarch64-darwin" ];
    };
  };
  mlx = py.buildPythonPackage {
    pname = "mlx";
    version = "0.32.3";
    format = "wheel";
    src = fetchurl {
      url = "https://files.pythonhosted.org/packages/4a/c1/13ff85d72f7cf01239c1031688b11cf1c7a3f0c7380636728976e510bfbd/mlx-0.32.3-cp312-cp312-macosx_26_0_arm64.whl";
      sha256 = "72711cb23cc6dccc5a460f63f39c11931a00b2c6dcd6fba253921090072e21bc";
    };
    propagatedBuildInputs = [ mlxMetal ];
    nativeBuildInputs = [ cctools ];
    postInstall = ''
      for binary in "$out"/${python312.sitePackages}/mlx/*.so; do
        install_name_tool -add_rpath "${mlxMetal}/${python312.sitePackages}/mlx/lib" "$binary"
      done
    '';
    pythonImportsCheck = [ "mlx.core" ];
    meta = {
      description = "MLX 0.32.3 runtime for macOS 26 Apple Silicon";
      license = lib.licenses.mit;
      platforms = [ "aarch64-darwin" ];
    };
  };
  safetensorsBase = py.buildPythonPackage {
    pname = "safetensors";
    version = "0.8.0";
    format = "wheel";
    src = fetchurl {
      url = "https://files.pythonhosted.org/packages/f5/b1/fa7c600e7dceae12e9606c7578cbc9ff1e1ed55844883ee5c92205e86226/safetensors-0.8.0-cp310-abi3-macosx_11_0_arm64.whl";
      sha256 = "c80201d22cbf405b80647a60ada77bba06c8fba2da2743ba1e89cdcc39a81f25";
    };
    propagatedBuildInputs = [ py.numpy ];
    pythonImportsCheck = [
      "safetensors"
      "safetensors.numpy"
    ];
    meta = {
      description = "Safetensors base runtime with NumPy support";
      license = lib.licenses.asl20;
      platforms = [ "aarch64-darwin" ];
    };
  };
  transformersBase = py.buildPythonPackage {
    pname = "transformers";
    version = "5.17.0";
    format = "wheel";
    src = fetchurl {
      url = "https://files.pythonhosted.org/packages/e8/d0/c502b60d684adbd98a8dc7d5bb866842772b816ac4354e4608be240041ae/transformers-5.17.0-py3-none-any.whl";
      sha256 = "78ec1ce21579b38dfb83950a0658cd119f87212a2fcfdff478096ce9d6c03801";
    };
    propagatedBuildInputs = with py; [
      huggingface-hub
      numpy
      packaging
      pyyaml
      regex
      tokenizers
      typer
      safetensorsBase
      tqdm
      jinja2
      protobuf
      sentencepiece
    ];
    pythonImportsCheck = [
      "transformers"
      "transformers.models.auto.tokenization_auto"
      "transformers.models.whisper.feature_extraction_whisper"
    ];
    postPythonImportsCheck = ''
      python -c 'from transformers import AutoTokenizer, WhisperFeatureExtractor'
    '';
    meta = {
      description = "Transformers base runtime without training extras";
      license = lib.licenses.asl20;
      platforms = [ "aarch64-darwin" ];
    };
  };
  mlxLm = py.buildPythonPackage {
    pname = "mlx-lm";
    version = "0.31.3";
    format = "wheel";
    src = fetchurl {
      url = "https://files.pythonhosted.org/packages/90/02/9a67b8e4f87e3e2e5cd7b1ad79304b93c09a0db6af34bee75e6551c06c60/mlx_lm-0.31.3-py3-none-any.whl";
      sha256 = "758cfddf1180053b7613db76fad3d246a331a2a905808e1164a275621fc983b8";
    };
    propagatedBuildInputs = [
      mlx
      transformersBase
      py.numpy
      py.sentencepiece
      py.protobuf
      py.pyyaml
      py.jinja2
    ];
    pythonImportsCheck = [ "mlx_lm" ];
    meta = {
      description = "MLX LM inference runtime without evaluation or training extras";
      license = lib.licenses.mit;
      platforms = [ "aarch64-darwin" ];
    };
  };
  mlxAudio = py.buildPythonPackage {
    pname = "mlx-audio";
    version = "0.5.8";
    format = "wheel";
    src = fetchurl {
      url = "https://files.pythonhosted.org/packages/77/b4/5fe7a122537321a1305c95d57280542691deddcd102fa8e84149525108bb/mlx_audio-0.5.8-py3-none-any.whl";
      sha256 = "cf2eaef3d5d965d3a0a5c98ab68d4867db51daace190a77b3b9576577a7d2eab";
    };
    propagatedBuildInputs = [
      mlx
      mlxLm
      transformersBase
      py.huggingface-hub
      py.miniaudio
      py.numpy
      py.scipy
      py.sounddevice
      py.tqdm
      py.sentencepiece
      py.zstandard
    ];
    pythonImportsCheck = [
      "mlx_audio.stt"
      "mlx_audio.stt.models.parakeet"
      "mlx_audio.stt.models.canary"
      "mlx_audio.stt.models.qwen3_asr"
    ];
    meta = {
      description = "MLX Audio speech-to-text runtimes without model weights";
      homepage = "https://github.com/Blaizzy/mlx-audio";
      license = lib.licenses.mit;
      platforms = [ "aarch64-darwin" ];
    };
  };
  runtimePython = python312.withPackages (p: [
    p.psutil
    mlxAudio
  ]);
  needleVersion = "3.2.0";
  needleWheel = fetchurl {
    url = "https://huggingface.co/Cactus-Compute/needle3/resolve/2ae11323dc000f5e70c49f7403efa6af12ba9e67/python/cactus_needle-${needleVersion}-py3-none-macosx_11_0_arm64.whl";
    sha256 = "3b0887a43cd6e9a99009fabf35b231c11bb3a978ab8af94b8119b2eb76e19832";
  };
  needleLibrary = runCommand "asr-needle-runtime-${needleVersion}" { } ''
    mkdir -p "$out/lib"
    ${python312}/bin/python -I - ${needleWheel} "$out/lib/libneedle3.dylib" <<'PY'
    import ctypes
    import sys
    import zipfile
    from pathlib import Path

    with zipfile.ZipFile(sys.argv[1]) as wheel:
        Path(sys.argv[2]).write_bytes(wheel.read("needle/libneedle3.dylib"))
    library = ctypes.CDLL(sys.argv[2])
    for symbol in ("needle_load", "needle_last_error", "needle_transcribe"):
        getattr(library, symbol)
    PY
  '';
in
stdenvNoCC.mkDerivation {
  pname = "asr-benchmark";
  version = "1.0.0";
  dontUnpack = true;
  nativeBuildInputs = [ makeWrapper ];
  installPhase = ''
    runHook preInstall
    install -Dm644 ${./asr-benchmark/runner.py} "$out/libexec/asr-benchmark/runner.py"
    install -Dm644 ${./asr-benchmark/backends.py} "$out/libexec/asr-benchmark/backends.py"
    makeWrapper ${runtimePython}/bin/python "$out/bin/asr-benchmark" \
      --add-flags "-s $out/libexec/asr-benchmark/runner.py" \
      --unset PYTHONPATH --unset PYTHONHOME \
      --prefix PATH : ${
        lib.makeBinPath [
          ffmpeg
          whisper-cpp
        ]
      } \
      --set ASR_NEEDLE_LIBRARY ${needleLibrary}/lib/libneedle3.dylib \
      --set ASR_NEEDLE_VERSION ${needleVersion} \
      --set ASR_WHISPER_SERVER ${lib.getExe' whisper-cpp "whisper-server"} \
      --set ASR_WHISPER_VERSION ${lib.escapeShellArg whisper-cpp.version} \
      --set HF_HUB_OFFLINE 1 --set TRANSFORMERS_OFFLINE 1 --set HF_DATASETS_OFFLINE 1 \
      --set NEEDLE_TELEMETRY 0 --set DO_NOT_TRACK 1 --set TOKENIZERS_PARALLELISM false
    runHook postInstall
  '';
  meta = {
    description = "Manual offline ASR benchmark with prepared runtimes and no model weights";
    platforms = [ "aarch64-darwin" ];
    mainProgram = "asr-benchmark";
  };
}
