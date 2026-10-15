{
  lib,
  beamMinimalPackages,
  sqlite,
}:

let
  beamPackages = beamMinimalPackages.overrideScope (_: prev: { elixir = prev.elixir_1_19; });
  pname = "fugate";
  version = "0.1.0";
  src = lib.cleanSourceWith {
    src = ./fugate;
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
beamPackages.mixRelease {
  inherit pname version src;

  mixFodDeps = beamPackages.fetchMixDeps {
    pname = "mix-deps-${pname}";
    inherit version src;
    hash = "sha256-n8MfSAYidaAMJ5X+i0GckW2Zh8nICz8HPJcf7Pa2P3w=";
  };

  # Build the exqlite NIF against nixpkgs' SQLite instead of a downloaded binary.
  env = {
    EXQLITE_USE_SYSTEM = "1";
    EXQLITE_SYSTEM_CFLAGS = "-I${sqlite.dev}/include";
    EXQLITE_SYSTEM_LDFLAGS = "-L${sqlite.out}/lib -lsqlite3";
  };

  meta = {
    description = "Unattended coding-agent scheduler driving Herdr";
    mainProgram = "fugate";
    platforms = lib.platforms.darwin ++ lib.platforms.linux;
  };
}
