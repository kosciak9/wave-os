{
  lib,
  stdenv,
  python313,
  fetchPypi,
}:
let
  py = python313.pkgs;
in
py.buildPythonApplication rec {
  pname = "mcp-email-server";
  version = "1.13.1";
  pyproject = true;

  src = fetchPypi {
    pname = "mcp_email_server";
    inherit version;
    hash = "sha256-62iMKP6bU7C/FBqKgviAn1JQ+tB1qa3U0BR+/O30ej0=";
  };

  build-system = [ py.hatchling ];
  pythonRelaxDeps = [ "filelock" ];
  dependencies =
    with py;
    [
      aioimaplib
      aiosmtplib
      anyio
      beautifulsoup4
      click
      filelock
      jinja2
      keyring
      loguru
      mcp
      pydantic
      pydantic-settings
      starlette
      tomli-w
      typer
      uvicorn
    ]
    ++ mcp.optional-dependencies.cli;
  nativeCheckInputs = with py; [
    pytestCheckHook
    pytest-asyncio
    pyyaml
  ];
  disabledTests = [
    # Build the wheel with uv and the UI with Node.
    "test_distribution_is_node_free_and_embeds_reproducible_ui"
    "test_isolated_wheel_and_local_uvx_serve_authenticated_ui"
    # Run the console script from the interpreter's bin directory.
    "test_raw_stdio_redacts_malformed_utf8_json_and_oversized_frames_then_recovers"
    "test_raw_stdio_broken_stdout_does_not_wait_for_open_stdin"
    "test_raw_stdio_accepts_regular_file_redirection_and_devnull_eof"
    "test_plugin_stdio_startup_failure_is_bounded_without_traceback"
  ];
  # The server refuses state under a directory owned by anyone but root or the user, and the
  # Linux build sandbox's root directory belongs to nobody.
  disabledTestPaths = lib.optionals stdenv.hostPlatform.isLinux [
    "tests/test_bootstrap.py"
    "tests/test_config.py"
    "tests/test_managed_catalog.py"
    "tests/test_managed_cli.py"
    "tests/test_managed_runtime_and_fences.py"
    "tests/test_management_adapters.py"
    "tests/test_metadata_index.py"
    "tests/test_mutation_class_policy.py"
    "tests/test_protocol_commands.py"
    "tests/test_read_adapters.py"
    "tests/test_web_ui_management.py"
    "tests/test_web_ui_server.py"
  ];
  pythonImportsCheck = [ "mcp_email_server.cli" ];

  meta = {
    description = "IMAP and SMTP MCP server with per-account mutation and recipient policies";
    homepage = "https://github.com/Wh1isper/mcp-email-server";
    license = lib.licenses.bsd3;
    mainProgram = "mcp-email-server";
    platforms = lib.platforms.unix;
  };
}
