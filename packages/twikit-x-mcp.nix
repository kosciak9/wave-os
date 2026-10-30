{
  lib,
  python313,
  fetchFromGitHub,
  fetchPypi,
  installShellFiles,
}:
let
  py = python313.pkgs;
  js2py = py.buildPythonPackage {
    pname = "js2py-3-13";
    version = "0.74.1";
    pyproject = true;
    src = fetchPypi {
      pname = "js2py_3_13";
      version = "0.74.1";
      hash = "sha256-keIU9xcxL51RDq82/MUyWwsVoipJgx/itDS8pKM8H3c=";
    };
    build-system = [ py.setuptools ];
    dependencies = with py; [
      tzlocal
      six
      pyjsparser
    ];
    pythonImportsCheck = [ "js2py_" ];
    meta.license = lib.licenses.mit;
  };
  webvtt = py.buildPythonPackage {
    pname = "webvtt-py";
    version = "0.5.1";
    pyproject = true;
    src = fetchPypi {
      pname = "webvtt-py";
      version = "0.5.1";
      hash = "sha256-IEDdMlJ33a3B4MbMZsvEodm2tJskxXoMM2Q3TD6KPcE=";
    };
    build-system = [ py.setuptools ];
    nativeBuildInputs = [ installShellFiles ];
    postInstall = ''
      cat > _webvtt <<'EOF'
      #compdef webvtt
      _arguments \
        '(-h --help)'{-h,--help}'[show help]' \
        '(-o --output)'{-o,--output}'[output directory]:directory:_directories' \
        '(-d --target-duration)'{-d,--target-duration}'[segment duration]:seconds:' \
        '(-m --mpegts)'{-m,--mpegts}'[presentation timestamp]:timestamp:' \
        '1:command:(segment)' \
        '2:WebVTT file:_files -g "*.vtt"'
      EOF
      installShellCompletion --zsh _webvtt
    '';
    checkPhase = ''
      runHook preCheck
      ${python313.interpreter} -m unittest discover
      runHook postCheck
    '';
    pythonImportsCheck = [ "webvtt" ];
    meta.license = lib.licenses.mit;
  };
in
py.buildPythonApplication {
  pname = "twikit-x-mcp";
  version = "0.1.1-unstable-2026-07-22";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "bintangtimurlangit";
    repo = "twikit-x-mcp";
    rev = "de1aba67960f150fa8769592c51da64f2d0eecdd";
    hash = "sha256-u3D8U2XwcFq0SVwBQSc+IQ3v/p8PSR8jirhENjQlEKY=";
  };
  patches = [ ./twikit-x-mcp/fail-closed-bootstrap.patch ];
  postPatch = ''
    cp ${./twikit-x-mcp/policy.py} twikit_x_mcp/policy.py
    cp ${./twikit-x-mcp/tools.json} twikit_x_mcp/tools.json
    substituteInPlace pyproject.toml \
      --replace-fail 'twikit = ["py.typed"]' $'twikit = ["py.typed"]\ntwikit_x_mcp = ["tools.json"]'
    substituteInPlace twikit_x_mcp/server.py \
      --replace-fail 'from .ratelimit import RateLimiter' $'from .ratelimit import RateLimiter\nfrom .policy import create_client, policy_tool' \
      --replace-fail '@mcp.tool()' '@policy_tool(mcp)' \
      --replace-fail 'client = Client(language=language, proxy=proxy)' 'client = await create_client(language)' \
      --replace-fail '        await _authenticate(client)' '        # Session cookies are loaded by create_client; no automated login.' \
      --replace-fail 'Literal["Tweets", "Replies", "Media", "Likes"]' 'Literal["Tweets", "Replies", "Media"]' \
      --replace-fail 'count: int = 40' 'count: int = 20'
  '';
  build-system = [ py.setuptools ];
  dependencies = with py; [
    mcp_1
    httpx
    socksio
    filetype
    beautifulsoup4
    pyotp
    lxml
    m3u8
    js2py
    webvtt
  ];
  nativeBuildInputs = [ installShellFiles ];
  nativeCheckInputs = [ py.pytestCheckHook ];
  pythonImportsCheck = [
    "twikit_x_mcp.server"
    "twikit_x_mcp.policy"
  ];
  postInstall = ''
    cat > _twikit-x-mcp <<'EOF'
    #compdef twikit-x-mcp
    _message 'stdio MCP server; no command-line arguments'
    EOF
    installShellCompletion --zsh _twikit-x-mcp
  '';
  meta = {
    description = "Read-only Twikit X MCP server with persistent HTTP budgets";
    homepage = "https://github.com/bintangtimurlangit/twikit-x-mcp";
    license = lib.licenses.mit;
    mainProgram = "twikit-x-mcp";
    platforms = lib.platforms.unix;
  };
}
