{
  lib,
  buildGoModule,
  fetchFromGitHub,
  installShellFiles,
}:
buildGoModule (finalAttrs: {
  pname = "whatsapp-mcp";
  version = "0.1.0-unstable-2026-09-26";
  src = fetchFromGitHub {
    owner = "hansen1101";
    repo = "whatsapp-mcp-server";
    rev = "275f6b809dfbc888fd20be9d7924ac9cb0691148";
    hash = "sha256-pDZqzC10/yq5e/fLlnMOrc3EhidBSwofarivQTshSo0=";
  };
  patches = [
    # Without the connection lock, serve would keep a server that never connects.
    ./whatsapp-mcp-exclusive.patch
    # download_media returns the file itself, not a path on this host.
    ./whatsapp-mcp-attachments.patch
  ];
  vendorHash = "sha256-U09bbr7oWLvM2pfKciwqre/n0MLpXOGAH0kITt/ztqg=";
  # go-sqlite3 is a cgo package.
  env.CGO_ENABLED = 1;
  ldflags = [
    "-s"
    "-w"
    "-X main.version=${finalAttrs.version}"
  ];
  nativeBuildInputs = [ installShellFiles ];
  postInstall = ''
    installShellCompletion --cmd whatsapp-mcp --zsh ${./whatsapp-mcp.zsh}
  '';
  meta = {
    description = "Read-only MCP server for a personal WhatsApp account, linked as a companion device";
    homepage = "https://github.com/hansen1101/whatsapp-mcp-server";
    license = lib.licenses.mit;
    mainProgram = "whatsapp-mcp";
  };
})
