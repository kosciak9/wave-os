{
  lib,
  rustPlatform,
  makeWrapper,
  installShellFiles,
  buildPackages,
  stdenv,
  curl,
  git,
  openssh,
  nvd,
  deploy-rs,
  deployNodes ? [ ],
}:
let
  completionProgram =
    if stdenv.buildPlatform.canExecute stdenv.hostPlatform then
      "$out/bin/wave"
    else
      lib.getExe buildPackages.wave;
in
rustPlatform.buildRustPackage {
  pname = "wave";
  version = "0.1.0";
  src = lib.cleanSourceWith {
    src = ../tools/wave;
    filter = path: type: lib.cleanSourceFilter path type && builtins.baseNameOf path != "target";
  };
  cargoLock.lockFile = ../tools/wave/Cargo.lock;

  nativeBuildInputs = [
    makeWrapper
    installShellFiles
  ];
  postInstall = ''
    installShellCompletion --cmd wave \
      --bash <(COMPLETE=bash ${completionProgram}) \
      --fish <(COMPLETE=fish ${completionProgram}) \
      --zsh <(COMPLETE=zsh ${completionProgram})
  '';
  postFixup = ''
    wrapProgram "$out/bin/wave" \
      --set WAVE_DEPLOY_NODES ${lib.escapeShellArg (builtins.toJSON deployNodes)} \
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
      "armv7l-linux"
    ];
  };
}
