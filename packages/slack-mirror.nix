{ lib, rustPlatform }:

rustPlatform.buildRustPackage {
  pname = "slack-mirror";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ./slack-mirror;
    fileset = lib.fileset.unions [
      ./slack-mirror/Cargo.toml
      ./slack-mirror/Cargo.lock
      ./slack-mirror/.cargo
      ./slack-mirror/src
    ];
  };
  cargoLock.lockFile = ./slack-mirror/Cargo.lock;
  meta = {
    description = "Independent Slack mirror and authenticated read-only MCP server";
    mainProgram = "wave-slack-mirror";
    platforms = lib.platforms.unix;
  };
}
