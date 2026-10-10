{
  lib,
  beamMinimalPackages,
}:

let
  pname = "wave-dashboard";
  version = "0.1.0";
  src = lib.cleanSourceWith {
    src = ./wave-dashboard;
    filter =
      path: type:
      lib.cleanSourceFilter path type
      && !builtins.elem (baseNameOf path) [
        "_build"
        "deps"
        "tmp"
      ];
  };
in
beamMinimalPackages.mixRelease {
  inherit pname version src;

  mixFodDeps = beamMinimalPackages.fetchMixDeps {
    pname = "mix-deps-${pname}";
    inherit version src;
    hash = "sha256-LbNDWQzQfLWgZVTFm7XrRQzAd+OVqwmlT8J36odxNag=";
  };

  meta = {
    description = "Wave home page and tailnet reverse proxy registry";
    mainProgram = "wave_dashboard";
    platforms = lib.platforms.linux;
  };
}
