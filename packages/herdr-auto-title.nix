{
  buildGoModule,
  src,
}:
buildGoModule {
  pname = "herdr-auto-title";
  version = "0.11.0";
  inherit src;
  vendorHash = "sha256-QxFp1b7pf7bn3Hh0hyaj8ke5Z61N+WwjhHt3pFiapTs=";
  subPackages = [ "cmd/herdr-auto-title" ];
  checkPhase = ''
    runHook preCheck
    go test ./...
    runHook postCheck
  '';
  meta.mainProgram = "herdr-auto-title";
}
