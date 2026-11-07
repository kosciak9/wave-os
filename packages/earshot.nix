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
  version = "0.4.1";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "Leonxlnx";
    repo = "earshot";
    rev = "4ac3d2ac2b151e1c23376f9ce7f3047a17050013";
    hash = "sha256-vRK2g/iPbPSJGum52yNO/lQ9Ch+7EQMtkrVZsr69Kwc=";
  };

  build-system = [ python3Packages.setuptools ];
  nativeBuildInputs = [ installShellFiles ];

  # MCP's subprocess environment must retain Nix's Python dependency paths.
  postPatch = ''
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
    "--prefix"
    "PATH"
    ":"
    (lib.makeBinPath [ ffmpeg ])
    "--set-default"
    "EARSHOT_THREADS"
    "3"
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
