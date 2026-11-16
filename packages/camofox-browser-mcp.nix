{
  buildNpmPackage,
  camofox-browser-source,
  lib,
  nodejs_22,
}:

buildNpmPackage {
  pname = "camofox-browser-mcp";
  inherit (camofox-browser-source) version src;
  sourceRoot = "${camofox-browser-source.src.name}/mcp";

  npmDepsHash = "sha256-wAHyCX+araEi4+PO8Pqn+t1lzL0cp8p93No6iMjmnXM=";
  nodejs = nodejs_22;
  dontNpmBuild = true;

  meta = {
    description = "Stdio MCP server over the Camofox browser REST API";
    homepage = "https://github.com/jo-inc/camofox-browser/tree/master/mcp";
    license = lib.licenses.mit;
    mainProgram = "camofox-browser-mcp";
    platforms = lib.platforms.unix;
  };
}
