{
  rustPlatform,
  perl,
  src,
}:
rustPlatform.buildRustPackage {
  pname = "herdr-agent-usage";
  version = "1.6.3";
  inherit src;
  cargoHash = "sha256-exraBUiHMUY+ED1czhveDQ1SvuKXoyBo1EA0lcWX+qM=";
  nativeCheckInputs = [ perl ];
  # Collector subprocess tests have short startup deadlines; avoid CPU contention.
  dontUseCargoParallelTests = true;
  patches = [ ./patches/herdr-agent-usage-dashboard-only.patch ];
  meta.mainProgram = "herdr-agent-usage";
}
