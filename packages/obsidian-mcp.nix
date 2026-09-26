{
  buildNpmPackage,
  fetchFromGitHub,
  lib,
  nodejs_22,
}:

buildNpmPackage {
  pname = "obsidian-mcp";
  version = "2.0.1";

  src = fetchFromGitHub {
    owner = "StevenStavrakis";
    repo = "obsidian-mcp";
    rev = "6d46b240b21836b7033f6a1ee9c295cb872775e7";
    hash = "sha256-n8EcM/pIZaoTs/0Qk45ghJ/Bp4NUzCuYIe/fizq4bbE=";
  };

  npmDepsHash = "sha256-6Ejwn3g97zoWI4WeH+pGlfYaZLyBdjvYfT97MwW1b88=";
  nodejs = nodejs_22;
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    npm test
    runHook postCheck
  '';

  passthru.gitHead = "6d46b240b21836b7033f6a1ee9c295cb872775e7";

  meta = {
    description = "Headless MCP server for local Obsidian vaults";
    homepage = "https://github.com/StevenStavrakis/obsidian-mcp";
    license = lib.licenses.mit;
    mainProgram = "obsidian-mcp";
    platforms = lib.platforms.unix;
  };
}
