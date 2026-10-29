{
  fetchurl,
  lib,
  makeWrapper,
  nodejs,
  stdenvNoCC,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "foxpilot-mcp";
  version = "1.0.33";

  src = fetchurl {
    url = "https://registry.npmjs.org/foxpilot-mcp/-/foxpilot-mcp-${finalAttrs.version}.tgz";
    hash = "sha256-I/HqYAi3UQfjcbEv39sYvS5At5idDRkxiY590Ayj3M8=";
  };

  sourceRoot = "package";
  dontBuild = true;
  dontConfigure = true;

  nativeBuildInputs = [ makeWrapper ];

  # The published package is a self-contained esbuild bundle without runtime dependencies.
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/libexec/foxpilot-mcp" "$out/bin"
    cp -R dist package.json "$out/libexec/foxpilot-mcp/"
    makeWrapper "${nodejs}/bin/node" "$out/bin/foxpilot-mcp" \
      --add-flags "$out/libexec/foxpilot-mcp/dist/server.js"
    runHook postInstall
  '';

  meta = {
    description = "MCP server driving Firefox through the FoxPilot extension";
    homepage = "https://github.com/balakumardev/foxpilot";
    license = lib.licenses.mit;
    mainProgram = "foxpilot-mcp";
    platforms = lib.platforms.unix;
  };
})
