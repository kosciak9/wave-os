{
  buildNpmPackage,
  fetchFromGitHub,
  lib,
  nodejs_22,
}:

buildNpmPackage {
  pname = "substack-mcp-cli";
  version = "2.2.2";

  src = fetchFromGitHub {
    owner = "thenavidm";
    repo = "substack-mcp-cli";
    rev = "e84d9a43d07ff33610507df31081cee0a3ac5f20";
    hash = "sha256-5ym4n292mqrgKcY/ZulLJkYHdVzb+2w95pspwbINcw4=";
  };

  npmDepsHash = "sha256-epx3H7UfZyC8A/VWDjZvMTigOOJGrykos8cAw7jzO1I=";
  nodejs = nodejs_22;
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    npm test
    runHook postCheck
  '';

  passthru.gitHead = "e84d9a43d07ff33610507df31081cee0a3ac5f20";

  meta = {
    description = "Substack MCP server and CLI for AI agents";
    homepage = "https://github.com/thenavidm/substack-mcp-cli";
    license = lib.licenses.mit;
    mainProgram = "substack-mcp";
    platforms = lib.platforms.unix;
  };
}
