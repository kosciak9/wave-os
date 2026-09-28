{
  fetchurl,
  cctools,
  lib,
  python312,
  runCommand,
  symlinkJoin,
  unzip,
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

  # Only the eight source modules required by the pinned Qwen3.5 backbone.
  # The upstream wheel's top-level __init__ eagerly loads Transformers and
  # generation APIs that this decision-only service must not import. Copy the
  # audited model/cache code plus its MIT license, not the rest of the wheel.
  mlxLmWheel = fetchurl {
    url = "https://files.pythonhosted.org/packages/90/02/9a67b8e4f87e3e2e5cd7b1ad79304b93c09a0db6af34bee75e6551c06c60/mlx_lm-0.31.3-py3-none-any.whl";
    sha256 = "758cfddf1180053b7613db76fad3d246a331a2a905808e1164a275621fc983b8";
  };
  mlxLmDecision =
    runCommand "browser-decision-mlx-lm-subset-0.31.3"
      {
        nativeBuildInputs = [ unzip ];
      }
      ''
        module="$out/lib/python3.12/site-packages/mlx_lm"
        mkdir -p "$module/models" "$out/share/licenses/browser-decision-mlx-lm"
        touch "$module/__init__.py" "$module/models/__init__.py"
        for file in base cache gated_delta qwen3_next qwen3_5 activations rope_utils switch_layers; do
          unzip -p ${mlxLmWheel} "mlx_lm/models/$file.py" > "$module/models/$file.py"
        done
        unzip -p ${mlxLmWheel} "mlx_lm-0.31.3.dist-info/licenses/LICENSE" > "$out/share/licenses/browser-decision-mlx-lm/LICENSE"
      '';

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

  baseRevision = "dc7cdfe2ee4154fa7e30f5b51ca41bfa40174e68";
  base =
    name: sha256:
    fetchurl {
      url = "https://huggingface.co/Qwen/Qwen3.5-0.8B-Base/resolve/${baseRevision}/${name}";
      inherit sha256;
    };
  adapterRevision = "9a45d25eb2ab761841196625383fa1dff0e56c1e";
  adapter =
    name: sha256:
    fetchurl {
      url = "https://huggingface.co/jaredpalmer/kev-0.8b/resolve/${adapterRevision}/${name}";
      inherit sha256;
    };
  baseFiles = runCommand "browser-decision-qwen-pinned" { } ''
    mkdir -p "$out"
    install -m644 ${base "model.safetensors-00001-of-00001.safetensors" "c2b1e5a17d9c1e27685d92ed9b382911ebb99955ecd89052d1721241adfbab6c"} "$out/model.safetensors-00001-of-00001.safetensors"
    install -m644 ${base "config.json" "b90b86f35c8e6925ef74ee04d0e758f0a845c83a42089ad82bbaa948de9b4204"} "$out/config.json"
    install -m644 ${base "tokenizer.json" "fe000e3ed39ed12b8d2481d527d44f93c65d37e87645d2dcc80d1bf9d50d2927"} "$out/tokenizer.json"
    install -m644 ${base "tokenizer_config.json" "e611fbccc7c29ef3b1cafb1cb7ea548d189968632901d678fd62be68c47885de"} "$out/tokenizer_config.json"
  '';
  adapterFiles = runCommand "browser-decision-kev-adapter-pinned" { } ''
    mkdir -p "$out"
    install -m644 ${adapter "adapter_config.json" "748acb2cda88454cb1ba69d745ba336f3fcb5486eac349e90960c8b8d8d3e854"} "$out/adapter_config.json"
    install -m644 ${adapter "adapter_model.safetensors" "9b908623acb162118575f4e7a94524f9c139c335be4bfb74d6cfceca01e1885a"} "$out/adapter_model.safetensors"
    install -m644 ${adapter "head.pt" "f400bd12802b2b105ae45d6b03774a158a3db4fccff42413734ddca2e5c920b6"} "$out/head.pt"
  '';

  # MLX converts on the CPU in the pure Nix build. A restricted four-tensor
  # decoder handles the SHA-pinned Torch ZIP without a PyTorch dependency.
  converter = python312.withPackages (ps: [
    (ps.toPythonModule mlxLmDecision)
    mlx
    ps.numpy
  ]);
  kevModel =
    runCommand "browser-decision-kev-0.8b-merged-q4"
      {
        nativeBuildInputs = [ converter ];
      }
      ''
        python ${./browser-decision/convert_model.py} \
          --base ${baseFiles} --adapter ${adapterFiles} --output "$out"
      '';

  runtimePython = python312.withPackages (ps: [
    layaMlx
    (ps.toPythonModule mlxLmDecision)
    mlx
    ps.numpy
    ps.tokenizers
  ]);
  app = writeShellApplication {
    name = "browser-decision";
    runtimeInputs = [ runtimePython ];
    text = ''
      export HF_HUB_OFFLINE=1 TOKENIZERS_PARALLELISM=false
      export OMP_NUM_THREADS=4 OPENBLAS_NUM_THREADS=1 VECLIB_MAXIMUM_THREADS=4
      case "''${1-}" in
        kev) exec ${runtimePython}/bin/python -I ${./browser-decision/runtime.py} --backend kev --model-dir ${kevModel} ;;
        laya) exec ${runtimePython}/bin/python -I ${./browser-decision/runtime.py} --backend laya --model-dir ${layaModel} ;;
        *) printf 'usage: browser-decision kev|laya\n' >&2; exit 2 ;;
      esac
    '';
  };
in
symlinkJoin {
  name = "browser-decision";
  paths = [ app ];
  passthru = {
    inherit
      kevModel
      layaModel
      mlxLmDecision
      runtimePython
      ;
  };
  meta = {
    description = "Offline Apple-MLX browser decision sidecar (Kev 4-bit and stock Laya v17s)";
    platforms = [ "aarch64-darwin" ];
    license = [
      lib.licenses.asl20
      lib.licenses.mit
    ];
    mainProgram = "browser-decision";
  };
}
