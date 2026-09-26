{
  stdenv,
  autoPatchelfHook,
  fetchurl,
  glibc,
  makeWrapper,
  ripgrep,
  sysctl,
  plannotator,
  lib,
}:

let
  version = "2.0.16";
  release =
    if stdenv.hostPlatform.isDarwin then
      {
        package = "cli-darwin-arm64";
        hash = "sha256-ChRGIx+R3luA4E/9xu7Fhoyl0h+ipmB2F0ze4TyydME=";
      }
    else
      {
        package = "cli-linux-x64";
        hash = "sha256-CCIetqeBNU6b47ORirW32Rr/LyBznn4uCvgbzcCCLIo=";
      };
in
stdenv.mkDerivation {
  pname = "opencode2";
  inherit version;

  src = fetchurl {
    url = "https://registry.npmjs.org/@opencode/${release.package}/-/${release.package}-${version}.tgz";
    inherit (release) hash;
  };

  nativeBuildInputs = [
    makeWrapper
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];

  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [ glibc ];

  dontUnpack = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    tar -xzf $src --strip-components=2 -C $out/bin package/bin/opencode
    mv $out/bin/opencode $out/bin/.opencode2-unwrapped
    makeWrapper $out/bin/.opencode2-unwrapped $out/bin/opencode2 \
      --prefix PATH : ${
        lib.makeBinPath [
          ripgrep
          sysctl
        ]
      } \
      --set PLANNOTATOR_BIN ${lib.getExe plannotator} \
      --run 'export XDG_CONFIG_HOME="''${HOME}/.config/opencode-v2" XDG_DATA_HOME="''${HOME}/.local/share/opencode-v2" XDG_CACHE_HOME="''${HOME}/.cache/opencode-v2" XDG_STATE_HOME="''${HOME}/.local/state/opencode-v2"'

    runHook postInstall
  '';

  meta = {
    description = "OpenCode v2 AI coding agent CLI";
    homepage = "https://github.com/anomalyco/opencode";
    license = lib.licenses.mit;
    mainProgram = "opencode2";
    platforms = [
      "aarch64-darwin"
      "x86_64-linux"
    ];
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
}
