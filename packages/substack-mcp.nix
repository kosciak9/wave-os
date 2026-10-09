{
  buildNpmPackage,
  fetchFromGitHub,
  lib,
  nodejs_22,
}:

buildNpmPackage {
  pname = "substack-mcp-cli";
  version = "3.0.1";

  src = fetchFromGitHub {
    owner = "thenavidm";
    repo = "substack-mcp-cli";
    rev = "dedc04046d3411d6a3cd1e71e49861d031b9f4ca";
    hash = "sha256-hkSi2DxXITZ8azqxN8St2imgyVfNQnD/gvhFGqtyCrk=";
  };

  npmDepsHash = "sha256-AVaAyb8ih3jGAtj7b7z7B3M/kKt1AjHDfIvigTe9uYI=";
  nodejs = nodejs_22;
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    npm test
    runHook postCheck
  '';

  passthru.gitHead = "dedc04046d3411d6a3cd1e71e49861d031b9f4ca";

  meta = {
    description = "Substack MCP server and CLI for AI agents";
    homepage = "https://github.com/thenavidm/substack-mcp-cli";
    license = lib.licenses.mit;
    mainProgram = "substack-mcp";
    platforms = lib.platforms.unix;
  };
}
