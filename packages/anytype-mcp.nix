{
  fetchurl,
  lib,
  makeWrapper,
  nodejs,
  stdenvNoCC,
}:

stdenvNoCC.mkDerivation {
  pname = "anytype-mcp";
  version = "1.2.10";

  src = fetchurl {
    url = "https://registry.npmjs.org/@anyproto/anytype-mcp/-/anytype-mcp-1.2.10.tgz";
    hash = "sha256-c/IagTpn3jFAxhVVWNhkWHMWN9KU2gUJwCfZwPKywpE=";
  };

  sourceRoot = "package";
  dontBuild = true;
  dontConfigure = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall
    cli="$out/libexec/anytype-mcp/bin/cli.mjs"
    install -Dm755 bin/cli.mjs "$cli"
    install -Dm644 LICENSE.md "$out/share/licenses/anytype-mcp/LICENSE.md"
    substituteInPlace "$cli" \
      --replace-fail 'console.error("prepareFileUpload",{operation:t,params:r});' "" \
      --replace-fail 'console.error(`extracting ''${s}`,{params:r});' "" \
      --replace-fail 'console.error("calling operation",{operationId:o,urlParameters:s,bodyParams:a,requestConfig:d});' "" \
      --replace-fail 'console.error("operation finished");' "" \
      --replace-fail 'console.error("Error in http client",l);' "" \
      --replace-fail 'console.error("calling tool",t.params);' "" \
      --replace-fail 'if(console.error("operations",this.openApiLookup),!o)' 'if(!o)' \
      --replace-fail 'if(console.error("Error in tool call",i),i instanceof nl)' 'if(i instanceof nl)' \
      --replace-fail 'console.error("HttpClientError encountered, returning structured error",i);' ""
    mkdir -p "$out/bin"
    makeWrapper "${nodejs}/bin/node" "$out/bin/anytype-mcp" \
      --add-flags "$cli"
    runHook postInstall
  '';

  passthru.gitHead = "4ba725d9c54f6ede43f49fe36c4dcb6498ab6677";

  meta = {
    description = "Anytype Model Context Protocol server";
    homepage = "https://github.com/anyproto/anytype-mcp";
    license = lib.licenses.mit;
    mainProgram = "anytype-mcp";
    platforms = lib.platforms.unix;
  };
}
