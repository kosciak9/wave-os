{
  fetchurl,
  cctools,
  lib,
  python313,
  runCommand,
  writeShellApplication,
}:
let
  py = python313.pkgs;

  # Use the upstream wheels matched to renekton's macOS 26 arm64.
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
      description = "MLX 0.32.3 arrays and ML inference on Apple Silicon";
      license = lib.licenses.mit;
      platforms = [ "aarch64-darwin" ];
    };
  };

  # laya-mlx's PyPI wheel is pure Python. Keep it separate from the upstream
  # model; neither is downloaded or executed at service startup.
  layaMlx = py.buildPythonPackage rec {
    pname = "laya-mlx";
    version = "0.3.0";
    format = "wheel";
    src = fetchurl {
      url = "https://files.pythonhosted.org/packages/48/84/f347d19c3d22e00a67e945f466b1319f784d66244d4dca4741bc9b433904/laya_mlx-0.3.0-py3-none-any.whl";
      sha256 = "6f3be5f292440d80c1c8fb8810ef5e82159a15295bd9894df7e574de325b49c3";
    };
    propagatedBuildInputs = [
      mlx
      py.huggingface-hub
      py.numpy
      py.tokenizers
    ];
    pythonImportsCheck = [ "laya_mlx" ];
    meta = {
      description = "Native MLX inference for Laya typed-decision models";
      homepage = "https://github.com/mizorewww/laya-mlx";
      license = lib.licenses.asl20;
      platforms = [ "aarch64-darwin" ];
    };
  };

  # Hash the individual pinned files: no unpinned snapshot, git-lfs pointer,
  # remote code, runtime hub cache, credentials or home-directory dependency.
  stockRevision = "ac29aefbc3a9b541f270e122e2e36d7e7081adaa";
  stock =
    name: sha256:
    fetchurl {
      url = "https://huggingface.co/cklxx/laya-browser/resolve/${stockRevision}/v17s/${name}";
      inherit sha256;
    };
  layaModel = runCommand "browser-decision-laya-v17s" { } ''
    mkdir -p "$out/encoder" "$out/tokenizer"
    install -m644 ${stock "model.safetensors" "7c2c2cf6f233593b05cc540130fe4bc12f84d3d93363e8fe638d27e23ae6d562"} "$out/model.safetensors"
    install -m644 ${stock "rl_agent_config.json" "4cff4659d902b537c46e9ac873724f01d03766d8ab41f8ac13fded4b5be1e1d4"} "$out/rl_agent_config.json"
    install -m644 ${stock "encoder/config.json" "fad4076bcae03044a509e35a2d36c1cdff482fd4c2d6e7c5d187bbc7d8b91590"} "$out/encoder/config.json"
    install -m644 ${stock "tokenizer/tokenizer.json" "609d8f4c067cd3950f88594c5a802616cea245823836ef5848ee4fc40aab5b6f"} "$out/tokenizer/tokenizer.json"
    install -m644 ${stock "tokenizer/tokenizer_config.json" "f2ff584a8f78ac9f3b6fd0afcf9ab310e41c2d445ef628f9ab4b0d594e992b7a"} "$out/tokenizer/tokenizer_config.json"
  '';

  runtimePython = python313.withPackages (_: [
    layaMlx
  ]);
in
writeShellApplication {
  name = "browser-decision";
  runtimeInputs = [ runtimePython ];
  text = ''
    export HF_HUB_OFFLINE=1 TOKENIZERS_PARALLELISM=false
    export OMP_NUM_THREADS=4 OPENBLAS_NUM_THREADS=1 VECLIB_MAXIMUM_THREADS=4
    case "''${1-}" in
      laya) exec ${runtimePython}/bin/python -I ${./browser-decision/runtime.py} --model-dir ${layaModel} ;;
      *) printf 'usage: browser-decision laya\n' >&2; exit 2 ;;
    esac
  '';
  meta = {
    description = "Offline Apple-MLX browser decision sidecar (stock Laya v17s)";
    platforms = [ "aarch64-darwin" ];
    license = lib.licenses.asl20;
    mainProgram = "browser-decision";
  };
}
