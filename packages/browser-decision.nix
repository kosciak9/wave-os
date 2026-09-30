{
  fetchurl,
  cctools,
  lib,
  python312,
  runCommand,
  writeShellApplication,
}:
let
  py = python312.pkgs;

  # The pinned nixpkgs snapshot has MLX 0.32.0, but laya-mlx 0.2.0 requires
  # >=0.32.2. Use the upstream wheels matched to renekton's macOS 26 arm64.
  mlxMetal = py.buildPythonPackage {
    pname = "mlx-metal";
    version = "0.32.2";
    format = "wheel";
    src = fetchurl {
      url = "https://files.pythonhosted.org/packages/dd/cd/4e50bf325100e7165e13d025f264362bf0009196269f9eaf87f2c6e738a2/mlx_metal-0.32.2-py3-none-macosx_26_0_arm64.whl";
      sha256 = "e6abeac9ac5265830c9c1541b6f96e9be37a85c2446763a46ad466c63a3837ab";
    };
    meta = {
      description = "MLX 0.32.2 Metal kernels";
      license = lib.licenses.mit;
      platforms = [ "aarch64-darwin" ];
    };
  };
  mlx = py.buildPythonPackage {
    pname = "mlx";
    version = "0.32.2";
    format = "wheel";
    src = fetchurl {
      url = "https://files.pythonhosted.org/packages/0b/eb/af6b1a8b45f24d22e4735c52e0696c66233bd477e1b9e9dbbef225bdf88b/mlx-0.32.2-cp312-cp312-macosx_26_0_arm64.whl";
      sha256 = "68560fd648c5bb900aa6f6765cd74c5a8abaf092d97d73584a57b7545966c227";
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
      description = "MLX 0.32.2 arrays and ML inference on Apple Silicon";
      license = lib.licenses.mit;
      platforms = [ "aarch64-darwin" ];
    };
  };

  # laya-mlx's PyPI wheel is pure Python. Keep it separate from the upstream
  # model; neither is downloaded or executed at service startup.
  layaMlx = py.buildPythonPackage rec {
    pname = "laya-mlx";
    version = "0.2.0";
    format = "wheel";
    src = fetchurl {
      url = "https://files.pythonhosted.org/packages/61/21/89b7f030fcbfb6327f1fc553480fbeaa2aae7408338ee422c2cf37746e66/laya_mlx-0.2.0-py3-none-any.whl";
      sha256 = "1a80a0cc79c55be808de0b1208a172566209b5780d796b98d86235e9cf335187";
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

  runtimePython = python312.withPackages (_: [
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
