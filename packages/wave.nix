{
  lib,
  rustPlatform,
  makeWrapper,
  curl,
  git,
  openssh,
  nvd,
  deploy-rs,
}:
rustPlatform.buildRustPackage {
  pname = "wave";
  version = "0.1.0";
  src = lib.cleanSourceWith {
    src = ../tools/wave;
    filter = path: type: lib.cleanSourceFilter path type && builtins.baseNameOf path != "target";
  };
  cargoLock.lockFile = ../tools/wave/Cargo.lock;

  nativeBuildInputs = [ makeWrapper ];
  postFixup = ''
    wrapProgram "$out/bin/wave" \
      --prefix PATH : "/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:${
        lib.makeBinPath [
          curl
          git
          openssh
          nvd
          deploy-rs
        ]
      }"
  '';

  meta = {
    description = "Wave OS source, switch and deployment CLI";
    mainProgram = "wave";
    platforms = [
      "x86_64-linux"
      "aarch64-darwin"
      "aarch64-linux"
    ];
  };
}
