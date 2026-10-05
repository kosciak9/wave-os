{ lib, stdenvNoCC }:

stdenvNoCC.mkDerivation {
  pname = "slack-mirror-context";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ./slack-mirror;
    fileset = lib.fileset.unions [
      ./slack-mirror/Cargo.toml
      ./slack-mirror/Cargo.lock
      ./slack-mirror/.cargo
      ./slack-mirror/src
      ./slack-mirror/Containerfile
    ];
  };
  dontBuild = true;
  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -R ./. "$out/"
    runHook postInstall
  '';
  meta = {
    description = "Immutable Linux build context for the standalone Slack mirror";
    platforms = lib.platforms.all;
  };
}
