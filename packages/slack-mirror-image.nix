{
  context,
  jq,
  lib,
  podman,
  stdenv,
  writeShellApplication,
}:

let
  contextPath = toString context;
  imageName = "localhost/wave-os/slack-mirror:${context.name}-${
    builtins.substring 0 32 (baseNameOf contextPath)
  }";
in
writeShellApplication {
  name = "slack-mirror-image-build";
  runtimeInputs = [
    podman
    jq
  ];
  text = ''
    machine="''${1:-wave-services}"
    case "$machine" in
      -*|*[!a-zA-Z0-9_-]*|"")
        printf '%s\n' "invalid services machine name" >&2
        exit 1
        ;;
    esac
    podman --connection "$machine" info --format json |
      jq -e '.host.security.rootless == true' >/dev/null
    if podman --connection "$machine" image inspect ${lib.escapeShellArg imageName} --format json 2>/dev/null |
      jq -e --arg context ${lib.escapeShellArg contextPath} \
        --arg arch ${lib.escapeShellArg (if stdenv.hostPlatform.isAarch64 then "arm64" else "amd64")} \
        '.[0].Config.Labels["io.wave-os.context"] == $context and
         .[0].Config.Labels["io.wave-os.component"] == "slack-mirror" and
         .[0].Os == "linux" and .[0].Architecture == $arch' >/dev/null; then
      exit 0
    fi
    exec podman --connection "$machine" build --pull=missing --http-proxy=false \
      --platform ${if stdenv.hostPlatform.isAarch64 then "linux/arm64" else "linux/amd64"} \
      --file ${lib.escapeShellArg "${contextPath}/Containerfile"} \
      --label ${lib.escapeShellArg "io.wave-os.context=${contextPath}"} \
      --tag ${lib.escapeShellArg imageName} ${lib.escapeShellArg contextPath}
  '';
  passthru = { inherit context imageName; };
}
