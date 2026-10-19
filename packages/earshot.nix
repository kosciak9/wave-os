{
  lib,
  python3Packages,
  fetchFromGitHub,
  ffmpeg,
  installShellFiles,
  callPackage,
  writableTmpDirAsHomeHook,
}:
let
  pyloudnorm = callPackage ./pyloudnorm.nix { inherit python3Packages; };
in
python3Packages.buildPythonPackage (finalAttrs: {
  pname = "earshot";
  version = "0.2.0";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "Leonxlnx";
    repo = "earshot";
    rev = "972132643583fc0b9a60c6c50983ed7dc1aa55bf";
    hash = "sha256-QTyYmuqPKjzFWQFBixivlLwH6G+N1tRIDcNFUHgKcgQ=";
  };

  build-system = [ python3Packages.setuptools ];
  nativeBuildInputs = [ installShellFiles ];

  # Keep the LLM sleep mock from intercepting subprocess's polling sleeps.
  patches = [ ./earshot-isolate-test-sleep.patch ];

  # Upstream's package-data omits the forge seed bank that forge v2 starts its search from.
  # MCP's subprocess environment must retain Nix's Python dependency paths.
  postPatch = ''
    substituteInPlace pyproject.toml \
      --replace-fail 'earshot = ["data/*.json", "data/*.npz"]' \
        'earshot = ["data/*.json", "data/*.npz", "forge/seeds/*.json"]'
    substituteInPlace tests/test_interfaces.py \
      --replace-fail "env={'EARSHOT_THREADS':" \
        "env={'PYTHONPATH': os.environ.get('PYTHONPATH', str()), 'EARSHOT_THREADS':"
  '';

  dependencies =
    with python3Packages;
    [
      numpy
      scipy
      soundfile
      soxr
      librosa
      scikit-learn
      pillow
      matplotlib
      torch
      transformers
      mcp
      requests
    ]
    ++ [ pyloudnorm ];

  makeWrapperArgs = [
    "--prefix PATH : ${lib.makeBinPath [ ffmpeg ]}"
    "--set-default EARSHOT_THREADS 3"
  ];

  postInstall = ''
    installShellCompletion --cmd earshot --zsh ${./earshot-completion.zsh}
  '';

  nativeCheckInputs = [
    python3Packages.pytestCheckHook
    ffmpeg
    writableTmpDirAsHomeHook
  ];
  pythonImportsCheck = [
    "earshot"
    "earshot.mcp_server"
  ];

  passthru.pythonEnvironment = python3Packages.python.withPackages (_: [ finalAttrs.finalPackage ]);

  meta = {
    description = "Local CPU audio analysis and sound design for coding agents";
    homepage = "https://github.com/Leonxlnx/earshot";
    license = lib.licenses.mit;
    mainProgram = "earshot";
  };
})
