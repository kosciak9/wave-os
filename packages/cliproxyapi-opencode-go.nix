{
  lib,
  stdenv,
  buildGoModule,
  fetchFromGitHub,
}:
# CLIProxyAPI native plugin that serves the OpenCode Go plan as one provider
# across Chat Completions, Messages and Responses.
buildGoModule (finalAttrs: {
  pname = "cliproxyapi-opencode-go";
  version = "0.2.2";

  src = fetchFromGitHub {
    owner = "massiveits";
    repo = "opencode-go-cliproxyapi";
    tag = "v${finalAttrs.version}";
    hash = "sha256-7T6YRBxqxKoOxzilItFGHDUdg6V4Lc3jJwO1KsT9VM0=";
  };

  vendorHash = "sha256-N/gri6Xm/1UNZyaLCPLUAuWswJ/DeVdpnFWnF7pKPUo=";

  env.CGO_ENABLED = 1;

  buildPhase = ''
    runHook preBuild
    go build -trimpath -buildmode=c-shared -ldflags "-s -w" \
      -o opencode-go-cliproxyapi${stdenv.hostPlatform.extensions.sharedLibrary} .
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm444 -t $out/lib opencode-go-cliproxyapi${stdenv.hostPlatform.extensions.sharedLibrary}
    runHook postInstall
  '';

  meta = {
    description = "OpenCode Go provider plugin for CLIProxyAPI";
    homepage = "https://github.com/massiveits/opencode-go-cliproxyapi";
    license = lib.licenses.mit;
  };
})
