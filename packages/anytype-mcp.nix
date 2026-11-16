{
  fetchurl,
  lib,
  makeWrapper,
  nodejs,
  stdenvNoCC,
}:

stdenvNoCC.mkDerivation {
  pname = "anytype-mcp";
  version = "2.0.2";

  src = fetchurl {
    url = "https://registry.npmjs.org/@anyproto/anytype-mcp/-/anytype-mcp-2.0.2.tgz";
    hash = "sha256-3/MgkblYXhe6wgiBu1S7QSgTk512Rg17XmOJ6v/Jj2E=";
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

  passthru.gitHead = "18f4ab6abb6f94b41da134b286a902924ba134f6";

  meta = {
    description = "Anytype Model Context Protocol server";
    homepage = "https://github.com/anyproto/anytype-mcp";
    license = lib.licenses.mit;
    mainProgram = "anytype-mcp";
    platforms = lib.platforms.unix;
  };
}
