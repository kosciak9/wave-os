{
  lib,
  cctools,
  fetchurl,
  python313,
  runCommand,
  stdenvNoCC,
  makeWrapper,
  ffmpeg,
  whisper-cpp,
}:
let
  py = python313.pkgs;
  huggingfaceHub = py.huggingface-hub.overridePythonAttrs (old: {
    version = "1.31.0";
    src = fetchurl {
      url = "https://files.pythonhosted.org/packages/9b/f0/61159db90b5cd275d55516fe27920828e7d3be4053fdbdb27c3f70e5f1ef/huggingface_hub-1.31.0.tar.gz";
      sha256 = "f8e9e710a210613fa5d0f26bba6da05ef4aef9fba5a0f23f508f5ac4d08b6f90";
    };
    meta = old.meta // {
      changelog = "https://github.com/huggingface/huggingface_hub/releases/tag/v1.31.0";
    };
  });
  tokenizers = py.tokenizers.override { huggingface-hub = huggingfaceHub; };
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
      url = "https://files.pythonhosted.org/packages/53/a9/70bf746c2cd13a198a429e33244d2f072ecd0c89508299a636529d3317cb/mlx-0.32.3-cp313-cp313-macosx_26_0_arm64.whl";
      sha256 = "75333afef55819afd2a31e87ffbed0bf59f379bca21771e6b13a95a675e4c85b";
    };
    propagatedBuildInputs = [ mlxMetal ];
    nativeBuildInputs = [ cctools ];
    postInstall = ''
      for binary in "$out"/${python313.sitePackages}/mlx/*.so; do
        install_name_tool -add_rpath "${mlxMetal}/${python313.sitePackages}/mlx/lib" "$binary"
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
    version = "5.19.0";
    format = "wheel";
    src = fetchurl {
      url = "https://files.pythonhosted.org/packages/b9/59/1e7f1212c215c73690ae6cab4678efe1555ff985953e145d88cc212859b0/transformers-5.19.0-py3-none-any.whl";
      sha256 = "afcd2dd5f603ed28c1e1fcb00a338ccbb4ef5f878ed289635df8b58187afb518";
    };
    propagatedBuildInputs = with py; [
      huggingfaceHub
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
    version = "0.32.0";
    format = "wheel";
    src = fetchurl {
      url = "https://files.pythonhosted.org/packages/88/ed/99cd7d36a1671851b41df06b59b73825bb95b8ab8b388ac871ddf9ae1523/mlx_lm-0.32.0-py3-none-any.whl";
      sha256 = "9a0f3843135fd88d36ad791f0d82210cdc4130c5c1cb5416f5f0c4b56a135778";
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
    version = "0.5.9";
    format = "wheel";
    src = fetchurl {
      url = "https://files.pythonhosted.org/packages/57/3c/5864cf8c30661049db2ed22d6c2ab1137691f3f49df3c1fd4c7b885953da/mlx_audio-0.5.9-py3-none-any.whl";
      sha256 = "fa662cf24cbca69cdd912612cdb677e65f77c6329a95906cc80b50e5b4689d6b";
    };
    propagatedBuildInputs = [
      mlx
      mlxLm
      transformersBase
      huggingfaceHub
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
  runtimePython = python313.withPackages (p: [
    p.psutil
    mlxAudio
  ]);
  needleVersion = "3.3.1";
  needleWheel = fetchurl {
    url = "https://huggingface.co/Cactus-Compute/needle3/resolve/93e88ede867e4311c39151285e74df513e4b835b/python/cactus_needle-${needleVersion}-py3-none-macosx_11_0_arm64.whl";
    sha256 = "19534f411ad71312031d6df5418d0e55b8d16075c28a217aef4b921349bdfb4a";
  };
  needleLibrary = runCommand "asr-needle-runtime-${needleVersion}" { } ''
    mkdir -p "$out/lib"
    ${python313}/bin/python -I - ${needleWheel} "$out/lib/libneedle3.dylib" <<'PY'
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
