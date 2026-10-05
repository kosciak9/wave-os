{
  lib,
  python313,
  fetchFromGitHub,
  writableTmpDirAsHomeHook,
}:
let
  python = python313;
  py = python.pkgs;
  dependencies = with py; [
    fastapi
    fastmcp
    google-api-python-client
    google-auth-httplib2
    google-auth-oauthlib
    httpx
    urllib3
    py-key-value-aio
    pyjwt
    python-dotenv
    pyyaml
    cryptography
    defusedxml
    email-validator
    pypdf
    pytz
    tzdata
    markdown-it-py
  ];
in
assert lib.versionAtLeast py.fastmcp.version "3.4.7";
assert lib.versionOlder py.fastmcp.version "4";
assert lib.versionAtLeast py.mcp.version "1.28.1";
assert lib.versionAtLeast py.pyasn1.version "0.6.4";
py.buildPythonApplication (finalAttrs: {
  pname = "workspace-mcp";
  version = "1.25.0";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "taylorwilsdon";
    repo = "google_workspace_mcp";
    rev = "984f06387f17c8afae8569239f60cb87efdf50df";
    hash = "sha256-mDf7iTag10XcMdSh5kirlu2yJKEpXug4EGIij9UQAzY=";
  };

  build-system = with py; [
    setuptools
    wheel
  ];

  inherit dependencies;

  doCheck = true;

  nativeCheckInputs = with py; [
    # Legacy synchronous checks rely on pytest-asyncio restoring the current loop.
    pytest8_3CheckHook
    (pytest-asyncio_0.override { pytest = pytest_8_3; })
    google-cloud-storage
    opentelemetry-sdk
    opentelemetry-exporter-otlp
    requests
    writableTmpDirAsHomeHook
  ];

  pythonImportsCheck = [
    "core.server"
    "core.cli"
    "gmail.gmail_tools"
    "gcalendar.calendar_tools"
  ];

  __darwinAllowLocalNetworking = true;

  passthru = {
    inherit python;
    pythonEnvironment = python.withPackages (_: dependencies);
    pythonPath = "${finalAttrs.finalPackage}/${python.sitePackages}";
  };

  meta = {
    description = "Google Workspace MCP server and CLI";
    homepage = "https://github.com/taylorwilsdon/google_workspace_mcp";
    changelog = "https://github.com/taylorwilsdon/google_workspace_mcp/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.mit;
    mainProgram = "workspace-mcp";
  };
})
