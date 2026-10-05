{
  lib,
  podman,
  jq,
  writeShellApplication,
}:

let
  source = lib.fileset.toSource {
    root = ../services/pi-assistants;
    fileset = lib.fileset.unions [
      ../services/pi-assistants/Containerfile
      ../services/pi-assistants/.dockerignore
      ../services/pi-assistants/package.json
      ../services/pi-assistants/package-lock.json
      ../services/pi-assistants/tsconfig.json
      ../services/pi-assistants/src
    ];
  };
  imageName = "localhost/wave-os/pi-assistants:${
    builtins.substring 0 32 (builtins.baseNameOf source)
  }";
in
writeShellApplication {
  name = "pi-assistants-image-build";
  runtimeInputs = [
    podman
    jq
  ];
  text = ''
    set -euo pipefail
    if ! podman --connection openclaw-sandbox info --format json |
      jq -e '.host.security.rootless == true' >/dev/null; then
      printf '%s\n' 'A running rootless openclaw-sandbox Podman machine is required.' >&2
      exit 1
    fi
    if podman --connection openclaw-sandbox image inspect ${lib.escapeShellArg imageName} \
      --format json 2>/dev/null |
      jq -e --arg source ${lib.escapeShellArg (toString source)} \
        '.[0].Config.Labels["io.wave-os.pi-assistants.source"] == $source' >/dev/null; then
      exit 0
    fi
    exec podman --connection openclaw-sandbox build \
      --platform linux/arm64 \
      --label ${lib.escapeShellArg "io.wave-os.pi-assistants.source=${source}"} \
      --tag ${lib.escapeShellArg imageName} \
      --file ${lib.escapeShellArg "${source}/Containerfile"} \
      ${lib.escapeShellArg (toString source)}
  '';
  passthru = { inherit imageName; };
}
