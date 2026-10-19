{
  buildNpmPackage,
  fetchFromGitHub,
  lib,
  nodejs_22,
}:

buildNpmPackage {
  pname = "substack-mcp-cli";
  version = "3.1.0";

  src = fetchFromGitHub {
    owner = "thenavidm";
    repo = "substack-mcp-cli";
    rev = "39eab6619c963d2358f2aae8b12da8e303b6bd73";
    hash = "sha256-1YH9GLKF/4o3oS6OKd6WJ/5RoNAo2I0rTEMABqmzDE0=";
  };

  npmDepsHash = "sha256-DtA+lc4ZVbidjBSmexqKtPjTjHOHVvi2ro9FIxGgCQU=";
  nodejs = nodejs_22;
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    npm test
    runHook postCheck
  '';

  passthru.gitHead = "39eab6619c963d2358f2aae8b12da8e303b6bd73";

  meta = {
    description = "Substack MCP server and CLI for AI agents";
    homepage = "https://github.com/thenavidm/substack-mcp-cli";
    license = lib.licenses.mit;
    mainProgram = "substack-mcp";
    platforms = lib.platforms.unix;
  };
}
