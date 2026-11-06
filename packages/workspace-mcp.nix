{
  lib,
  python313,
  fetchFromGitHub,
  writableTmpDirAsHomeHook,
  installShellFiles,
}:
let
  # The version comes from UV_DYNAMIC_VERSIONING_BYPASS, which nixpkgs' 0.13 honours too.
  relaxUvDynamicVersioning = ''
    substituteInPlace src/httpx2/pyproject.toml src/httpcore2/pyproject.toml \
      --replace-fail '"uv-dynamic-versioning>=0.14.1"' '"uv-dynamic-versioning"'
  '';
  # workspace-mcp 2.x needs FastMCP 4, which nixpkgs does not have yet;
  # the overrides are scoped to this package's interpreter.
  python = python313.override {
    self = python;
    packageOverrides = final: prev: {
      google-api-python-client = prev.google-api-python-client.overridePythonAttrs rec {
        version = "2.201.0";
        src = fetchFromGitHub {
          owner = "googleapis";
          repo = "google-api-python-client";
          tag = "v${version}";
          # The generated docs contain names differing only in case, so the
          # unpacked tree would hash differently on case-insensitive Darwin.
          postFetch = "rm -r $out/docs";
          hash = "sha256-ymzuPB8LnJcQ9uTrv/3v/QAzRlFTuc96ITh8UY4TONc=";
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

      # FastMCP's task backend needs Redis credential providers from Docket 0.26.1.
      pydocket = prev.pydocket.overridePythonAttrs (old: {
        version = "0.26.1";
        src = fetchFromGitHub {
          owner = "chrisguidry";
          repo = "docket";
          tag = "python/v0.26.1";
          hash = "sha256-2OVo3ZZlX3Fg3Vi3ipUmWIyWDcOVmv1xJi3khhHJJFw=";
        };
        postUnpack = (old.postUnpack or "") + ''
          sourceRoot+=/python
        '';
      });

      # FastMCP validates OpenAPI 3.1.2, supported since 0.6.
      openapi-pydantic = prev.openapi-pydantic.overridePythonAttrs rec {
        version = "0.6.0";
        src = fetchFromGitHub {
          owner = "mike-oakley";
          repo = "openapi-pydantic";
          tag = "v${version}";
          hash = "sha256-8vjZ2Sy5LY3h5PacLyUIga/xorGM27WmWxAHI6i7wUs=";
        };
        build-system = [ final.hatchling ];
      };

      fastmcp-slim = prev.fastmcp-slim.overridePythonAttrs (old: {
        # nixpkgs marks FastMCP 3 as incompatible with MCP 2; this package uses FastMCP 4.
        meta = old.meta // {
          broken = false;
        };
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
      });

      fastmcp = prev.fastmcp.overridePythonAttrs (old: rec {
        version = "4.1.6";
        src = fetchFromGitHub {
          owner = "PrefectHQ";
          repo = "fastmcp";
          tag = "v${version}";
          hash = "sha256-FzJkoFfmbgS/XQn+5JjegcrqMF7jTy8Wnq6jHcrCZK8=";
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
          # Needs the unpackaged prefab-ui.
          "tests/server/test_session_scope.py"
          # Code mode needs pydantic-monty 1.1, newer than nixpkgs has.
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
assert lib.versionAtLeast py.fastmcp.version "4.1.2";
assert lib.versionOlder py.fastmcp.version "5";
assert lib.versionAtLeast py.mcp.version "2.2.0";
assert lib.versionAtLeast py.pyasn1.version "0.6.4";
py.buildPythonApplication (finalAttrs: {
  pname = "workspace-mcp";
  version = "2.3.0";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "taylorwilsdon";
    repo = "google_workspace_mcp";
    tag = "v${finalAttrs.version}";
    hash = "sha256-wUqsnVQYCa9oPbXlDE7Z5dOZpCfYpbDpsCuYWhqAuGI=";
  };

  build-system = with py; [
    setuptools
    wheel
  ];

  nativeBuildInputs = [ installShellFiles ];
  postInstall = ''
    for command in workspace-mcp workspace-cli; do
      installShellCompletion --cmd "$command" --zsh \
        <(printf '#compdef %s\n_gnu_generic\n' "$command")
    done
  '';

  inherit dependencies;

  # Keep nixpkgs' shared dependencies until it catches up with upstream's security
  # floors; overriding them here would rebuild much of this interpreter.
  pythonRelaxDeps = [
    "urllib3"
    "opentelemetry-api"
    "dnspython"
  ];

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
