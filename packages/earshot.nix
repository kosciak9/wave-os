{
  lib,
  python3Packages,
  fetchFromGitHub,
  ffmpeg,
  installShellFiles,
  writableTmpDirAsHomeHook,
}:
python3Packages.buildPythonPackage (finalAttrs: {
  pname = "earshot";
  version = "1.0.0";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "Leonxlnx";
    repo = "earshot";
    rev = "7a7f7c5c70d4a763a1eca4b3666af7c77e313f97";
    hash = "sha256-wMAmFjs/M3fc0VT+wMSQDJbJS06NbBWExiJeD5Nyuzc=";
  };

  build-system = [ python3Packages.setuptools ];
  nativeBuildInputs = [
    installShellFiles
    python3Packages.shtab
  ];

  # Test subprocesses must retain Nix's Python dependency paths, which come through PYTHONPATH.
  # In one pytest process with every extra installed, earlier tests have already imported
  # torch; test_install_surface checks that making sounds loads none in a fresh process.
  postPatch = ''
    substituteInPlace tests/test_interfaces.py \
      --replace-fail "env={'EARSHOT_THREADS':" \
        "env={'PYTHONPATH': os.environ.get('PYTHONPATH', str()), 'EARSHOT_THREADS':"
    substituteInPlace tests/test_install_surface.py \
      --replace-fail "'PYTHONPATH': str(ROOT)}" \
        "'PYTHONPATH': os.pathsep.join([str(ROOT), os.environ.get('PYTHONPATH', str())])}"
    substituteInPlace tests/test_recipe.py \
      --replace-fail "'PYTHONPATH': str(root)})" \
        "'PYTHONPATH': os.pathsep.join([str(root), os.environ.get('PYTHONPATH', str())])})"
    substituteInPlace tests/test_sounds_atlas.py \
      --replace-fail "    from earshot.make import make
        r = make('a soft success chime'" \
        "    from earshot.make import make
        torch_before = 'torch' in sys.modules
        r = make('a soft success chime'" \
      --replace-fail "assert 'torch' not in sys.modules" \
        "assert torch_before or 'torch' not in sys.modules"
  '';

  # The base install plus every extra: listen, measure, images, mcp and llm.
  dependencies = with python3Packages; [
    numpy
    scipy
    soundfile
    soxr
    numba
    torch
    transformers
    huggingface-hub
    librosa
    matplotlib
    pillow
    mcp
    pydantic
    requests
  ];

  makeWrapperArgs = [
    "--prefix"
    "PATH"
    ":"
    (lib.makeBinPath [ ffmpeg ])
    "--set-default"
    "EARSHOT_THREADS"
    "3"
  ];

  # The CLI registers its commands in main(), so build the full parser the same way.
  postInstall = ''
    PYTHONPATH="$out/${python3Packages.python.sitePackages}:$PYTHONPATH" ${python3Packages.python.interpreter} -c '
    import shtab
    from earshot import cli
    parser = cli._parser()
    commands = parser.add_subparsers(dest="command", metavar="<command>")
    assert not cli._register(commands, list(cli.COMMANDS.values()))
    print(shtab.complete(parser, "zsh"))
    ' > _earshot
    installShellCompletion --zsh _earshot
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
