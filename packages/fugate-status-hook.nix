{ lib, rustPlatform }:

rustPlatform.buildRustPackage {
  pname = "fugate-status-hook";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ./fugate-status-hook;
    fileset = lib.fileset.unions [
      ./fugate-status-hook/Cargo.toml
      ./fugate-status-hook/Cargo.lock
      ./fugate-status-hook/src
    ];
  };
  cargoLock.lockFile = ./fugate-status-hook/Cargo.lock;
  meta = {
    description = "Agent turn hook that reports Fugate status lines to Herdr";
    mainProgram = "fugate-status-hook";
    platforms = lib.platforms.unix;
  };
}
