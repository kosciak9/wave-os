{
  fetchurl,
  lib,
  makeWrapper,
  nodejs,
  stdenvNoCC,
}:

stdenvNoCC.mkDerivation {
  pname = "anytype-mcp";
  version = "2.0.1";

  src = fetchurl {
    url = "https://registry.npmjs.org/@anyproto/anytype-mcp/-/anytype-mcp-2.0.1.tgz";
    hash = "sha256-DnsrX5DS0/aUQ/jU59+FcJHEbkt4ob3sSNEqEjnInzI=";
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
    mkdir -p "$out/bin"
    makeWrapper "${nodejs}/bin/node" "$out/bin/anytype-mcp" \
      --add-flags "$cli"
    runHook postInstall
  '';

  passthru.gitHead = "0134fe8cc2341d1bf90f310c7606b5345b636c21";

  meta = {
    description = "Anytype Model Context Protocol server";
    homepage = "https://github.com/anyproto/anytype-mcp";
    license = lib.licenses.mit;
    mainProgram = "anytype-mcp";
    platforms = lib.platforms.unix;
  };
}
