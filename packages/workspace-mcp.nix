{
  lib,
  python313,
  fetchFromGitHub,
  writableTmpDirAsHomeHook,
}:
let
  # The version comes from UV_DYNAMIC_VERSIONING_BYPASS, which nixpkgs' 0.13 honours too.
  relaxUvDynamicVersioning = ''
    substituteInPlace src/httpx2/pyproject.toml src/httpcore2/pyproject.toml \
      --replace-fail '"uv-dynamic-versioning>=0.14.1"' '"uv-dynamic-versioning"'
  '';
  # workspace-mcp 2.x needs FastMCP 4 and the MCP SDK 2, which the pinned nixpkgs
  # does not have yet; they are scoped to this package's interpreter. The versions are
  # the ones upstream locks: FastMCP 4.1 changes HTTP session expiry and Google token
  # caching in ways workspace-mcp's tests reject.
  python = python313.override {
    self = python;
    packageOverrides = final: prev: {
      # workspace-mcp's security floor.
      pyjwt = prev.pyjwt.overridePythonAttrs rec {
        version = "2.15.1";
        src = fetchFromGitHub {
          owner = "jpadilla";
          repo = "pyjwt";
          tag = version;
          hash = "sha256-C2l0QN8Vg2WkWniAfN/jpC6LAuy6gjcigzK1dvfJnj8=";
        };
      };

      httpcore2 = prev.httpcore2.overridePythonAttrs (old: {
        inherit (final.httpx2) version src;
        postPatch = relaxUvDynamicVersioning + old.postPatch;
      });

      httpx2 = prev.httpx2.overridePythonAttrs (old: rec {
        version = "2.14.0";
        src = fetchFromGitHub {
          owner = "pydantic";
          repo = "httpx2";
          tag = "v${version}";
          hash = "sha256-B3sLgMfJIzsM0gDVgvTEFeil0q7VG+xt0jgUcfPVU9w=";
        };
        postPatch = relaxUvDynamicVersioning + old.postPatch;
        dependencies = old.dependencies ++ [ final.truststore ];
      });

      mcp-types = final.buildPythonPackage {
        pname = "mcp-types";
        inherit (final.mcp) version src;
        sourceRoot = "${final.mcp.src.name}/src/mcp-types";
        pyproject = true;

        build-system = with final; [
          hatchling
          uv-dynamic-versioning
        ];

        dependencies = with final; [
          pydantic
          typing-extensions
        ];

        # Upstream tests run in the mcp package.
        pythonImportsCheck = [ "mcp_types" ];

        meta = {
          description = "Model Context Protocol wire types";
          homepage = "https://github.com/modelcontextprotocol/python-sdk/tree/main/src/mcp-types";
          license = lib.licenses.mit;
        };
      };

      mcp = prev.mcp.overridePythonAttrs (old: rec {
        version = "2.2.0";
        src = fetchFromGitHub {
          owner = "modelcontextprotocol";
          repo = "python-sdk";
          tag = "v${version}";
          hash = "sha256-nnpNXnQiFSGx5KQBDXHCOH0wE3cznlmI6s7vtchcj3A=";
        };
        # nixpkgs lengthens a stdio test's sleep on Darwin; 2.x's tests no longer sleep there.
        postPatch = "";
        pythonRelaxDeps = [ ];
        dependencies =
          with final;
          [
            anyio
            httpx2
            jsonschema
            mcp-types
            opentelemetry-api
            pydantic
            pyjwt
            python-multipart
            sse-starlette
            starlette
            typing-extensions
            typing-inspection
            uvicorn
          ]
          ++ pyjwt.optional-dependencies.crypto;
        optional-dependencies = {
          cli = with final; [
            python-dotenv
            typer
          ];
          rich = [ final.rich ];
        };
        nativeCheckInputs = with final; [
          blockbuster
          coverage
          dirty-equals
          griffelib
          inline-snapshot
          logfire
          opentelemetry-sdk
          pillow
          pytest-examples
          pytest-xdist
          pytestCheckHook
          trio
          python-dotenv
          pyyaml
          typer
          rich
        ];
        # The example stories run as a test plugin from the source tree.
        preCheck = ''
          export PYTHONPATH="$PWD/examples:$PYTHONPATH"
        '';
        disabledTestPaths = [
          # Documentation translation tooling, which needs the unpackaged Zensical.
          "tests/docs/test_translations.py"
        ];
        disabledTests = old.disabledTests ++ [
          # The stdio server subprocess gets a minimal environment without PYTHONPATH,
          # so it cannot import mcp from the build sandbox.
          "test_client_with_stdio_parameters_launches_the_server_as_a_subprocess"
          "test_tool_call_and_notification_round_trip_over_a_stdio_subprocess"
          "test_a_tool_spawned_childs_stdout_writes_never_reach_the_wire"
        ];
      });

      fastmcp-slim = prev.fastmcp-slim.overridePythonAttrs {
        patches = [ ];
        dependencies =
          with final;
          [
            mcp-types
            platformdirs
            pydantic
            pydantic-settings
            python-dotenv
            rich
            typing-extensions
          ]
          ++ pydantic.optional-dependencies.email;
        optional-dependencies =
          let
            keyValue = [
              final.py-key-value-aio
            ]
            ++ (with final.py-key-value-aio.optional-dependencies; filetree ++ keyring ++ memory);
            mcpClient = with final; [
              exceptiongroup
              httpx2
              mcp
              opentelemetry-api
              starlette
            ];
          in
          {
            mcp = mcpClient;
            anthropic = [ final.anthropic ];
            azure = with final; [
              azure-identity
              pyjwt
            ];
            client = [ final.authlib ] ++ mcpClient ++ keyValue;
            gemini = with final; [
              google-genai
              jsonref
            ];
            openai = [ final.openai ];
            server =
              with final;
              [
                authlib
                cyclopts
                griffelib
                joserfc
                jsonref
                jsonschema-path
                openapi-pydantic
                packaging
                pyperclip
                python-multipart
                pyyaml
                uncalled-for
                uvicorn
                watchfiles
                websockets
              ]
              ++ mcpClient
              ++ keyValue;
          };
      };

      fastmcp = prev.fastmcp.overridePythonAttrs (old: rec {
        version = "4.0.10";
        src = fetchFromGitHub {
          owner = "PrefectHQ";
          repo = "fastmcp";
          tag = "v${version}";
          hash = "sha256-GAoBN+tvwRGLrq3+XXvJYaeL3X5HoHFzyQodzNMLAwY=";
        };
        patches = [ ];
        optional-dependencies = {
          inherit (final.fastmcp-slim.optional-dependencies)
            anthropic
            azure
            gemini
            openai
            ;
        };
        nativeCheckInputs =
          with final;
          [
            dirty-equals
            fastapi
            inline-snapshot
            opentelemetry-sdk
            psutil
            pytest-asyncio
            pytest-env
            pytest-examples
            pytest-httpx
            pytest-rerunfailures
            pytest-timeout
            pytest-xdist
            pytestCheckHook
            writableTmpDirAsHomeHook
            anthropic
            azure-identity
            google-genai
            openai
            # The tests import the tasks workspace package, which needs Docket.
            pydocket
          ]
          ++ inline-snapshot.optional-dependencies.dirty-equals;
        disabledTestPaths = old.disabledTestPaths ++ [
          # Code mode needs pydantic-monty 0.0.21, newer than nixpkgs has.
          "tests/experimental/transforms/test_code_mode.py"
        ];
        disabledTests = old.disabledTests ++ [
          # Needs the unpackaged prefab-ui.
          "TestPickerForm"
          # Code mode, as above.
          "test_code_mode_returns_task_tool_result"
        ];
      });
    };
  };
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
assert lib.versionAtLeast py.fastmcp.version "4.0.10";
assert lib.versionOlder py.fastmcp.version "5";
assert lib.versionAtLeast py.mcp.version "2.2.0";
assert lib.versionAtLeast py.pyasn1.version "0.6.4";
py.buildPythonApplication (finalAttrs: {
  pname = "workspace-mcp";
  version = "2.1.1";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "taylorwilsdon";
    repo = "google_workspace_mcp";
    tag = "v${finalAttrs.version}";
    hash = "sha256-gX4N1xKwE0FxcXZycuNExihx0yha9jt+BnlQ7GGEtCE=";
  };

  build-system = with py; [
    setuptools
    wheel
  ];

  inherit dependencies;

  # Upstream's security floor wants urllib3 2.8; raising it here would rebuild some
  # 200 packages of this interpreter, so the urllib3 of nixpkgs stays until it catches up.
  pythonRelaxDeps = [ "urllib3" ];

  doCheck = true;

  nativeCheckInputs = with py; [
    # Legacy synchronous checks rely on pytest-asyncio restoring the current loop.
    pytest8_3CheckHook
    (pytest-asyncio_0.override { pytest = pytest_8_3; })
    google-cloud-storage
    httpx2
    opentelemetry-sdk
    opentelemetry-exporter-otlp
    requests
    writableTmpDirAsHomeHook
  ];

  # The external OAuth provider frees its validation slot in a future callback that
  # Python 3.13 runs only after the awaiting coroutine resumes, so these back-to-back
  # validations find the slot still taken. It serves HTTP mode only, not stdio.
  disabledTests = [
    "test_validation_failure_returns_none_and_releases_capacity"
    "test_validation_cache_is_off_by_default"
    "test_cached_token_skips_userinfo_and_keeps_its_identity"
    "test_cached_token_is_revalidated_after_ttl"
    "test_failed_validation_is_not_cached"
    "test_validation_cache_is_bounded"
    "test_invalid_identity_is_not_cached"
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
