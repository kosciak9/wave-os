{
  lib,
  buildGoModule,
  fetchFromGitHub,
  installShellFiles,
}:
buildGoModule (finalAttrs: {
  pname = "mcp-proxy";
  version = "1.1.0";
  src = fetchFromGitHub {
    owner = "TBXark";
    repo = "mcp-proxy";
    tag = "v${finalAttrs.version}";
    hash = "sha256-g3up2T63z6sbswtXryfgmO7j3QrjfRICqJmFayQoi7g=";
  };
  vendorHash = "sha256-yLJrc9gbnzNEdjYg8XhXwRGKmc+p7xTjX1eZfWMKc2Q=";
  subPackages = [ "." ];
  ldflags = [
    "-s"
    "-w"
    "-X main.BuildVersion=${finalAttrs.version}"
  ];
  nativeBuildInputs = [ installShellFiles ];
  postInstall = ''
    installShellCompletion --cmd mcp-proxy --zsh ${./mcp-gateway.zsh}
  '';
  meta = {
    description = "MCP gateway with shared upstream OAuth sessions";
    homepage = "https://github.com/TBXark/mcp-proxy";
    license = lib.licenses.mit;
    mainProgram = "mcp-proxy";
  };
})
