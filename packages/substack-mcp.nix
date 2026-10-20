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
    rev = "8eadfa5c1ee42af611a31bccae85548d8ea703fc";
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

  passthru.gitHead = "8eadfa5c1ee42af611a31bccae85548d8ea703fc";

  meta = {
    description = "Substack MCP server and CLI for AI agents";
    homepage = "https://github.com/thenavidm/substack-mcp-cli";
    license = lib.licenses.mit;
    mainProgram = "substack-mcp";
    platforms = lib.platforms.unix;
  };
}
