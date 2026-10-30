{
  lib,
  stdenv,
  python313,
  fetchPypi,
  fetchFromGitHub,
  vmTools,
  installShellFiles,
}:
let
  python = python313.override {
    self = python;
    packageOverrides = final: prev: {
      # Typer 0.25 relies on Click 8.3's command and error-formatting API.
      click = prev.click.overridePythonAttrs {
        version = "8.3.3";
        src = fetchFromGitHub {
          owner = "pallets";
          repo = "click";
          tag = "8.3.3";
          hash = "sha256-LcnAI4hyiuaJ4qnFnbAR5Cft/yvW5tAIjY6qc6K/Nrw=";
        };
      };

      # Its CLI inspects Click commands; Typer 0.26+ vendors incompatible command classes.
      typer = prev.typer.overridePythonAttrs (old: {
        version = "0.25.1";
        src = fetchFromGitHub {
          owner = "fastapi";
          repo = "typer";
          tag = "0.25.1";
          hash = "sha256-HIvXseuR7zUXFuTWzntDfHhAp8BcFjxo35gn0i4+03w=";
        };
        dependencies = old.dependencies ++ [ final.click ];
      });

      # The overridden interpreter rebuilds aiohttp, whose Darwin tests may reach
      # the host's network: this one connects to https://127.0.0.1 and leaks the
      # socket whenever a local service listens on port 443.
      aiohttp = prev.aiohttp.overridePythonAttrs (old: {
        disabledTests =
          old.disabledTests
          ++ lib.optionals stdenv.hostPlatform.isDarwin [ "test_connector_multiple_event_loop" ];
      });
    };
  };
  py = python.pkgs;
  package = py.buildPythonApplication rec {
    pname = "mcp-email-server";
    version = "1.13.3";
    pyproject = true;

    src = fetchPypi {
      pname = "mcp_email_server";
      inherit version;
      hash = "sha256-HI3mooCX5jf2RZ9W44GFmf1J+nS7ydhbXSNVXtf66mo=";
    };

    build-system = [ py.hatchling ];
    nativeBuildInputs = [ installShellFiles ];
    postInstall = ''
      PYTHONPATH="$out/${python.sitePackages}:$PYTHONPATH" HOME="$TMPDIR/completion-home" \
        _MCP_EMAIL_SERVER_COMPLETE=source_zsh "$out/bin/mcp-email-server" > _mcp-email-server
      # compinit reads only the first line; Typer prefixes the script with a blank line.
      sed -i '/./,$!d' _mcp-email-server
      test "$(head -n 1 _mcp-email-server)" = '#compdef mcp-email-server'
      installShellCompletion --zsh _mcp-email-server
    '';
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
        mcp_1
        pydantic
        pydantic-settings
        starlette
        tomli-w
        typer
        uvicorn
      ]
      ++ mcp_1.optional-dependencies.cli;
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
    ]
    ++ lib.optionals stdenv.hostPlatform.isDarwin [
      # Store secrets in the build user's real keychain, which persists across builds.
      "test_managed_roundtrip_nullable_override_reset"
      "test_create_account_persists_mutation_grants_and_drafts_mailbox"
    ];
    pythonImportsCheck = [ "mcp_email_server.cli" ];

    meta = {
      description = "IMAP and SMTP MCP server with per-account mutation and recipient policies";
      homepage = "https://github.com/Wh1isper/mcp-email-server";
      license = lib.licenses.bsd3;
      mainProgram = "mcp-email-server";
      platforms = lib.platforms.unix;
    };
  };
in
# Its directory-security checks need a root-owned /, unlike the Linux build sandbox.
if stdenv.hostPlatform.isLinux then vmTools.runInLinuxVM package else package
