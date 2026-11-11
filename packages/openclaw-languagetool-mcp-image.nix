{
  context,
  jq,
  lib,
  podman,
  stdenv,
  writeShellApplication,
}:

let
  imageName = "localhost/wave-os/openclaw-languagetool-mcp:${lib.getVersion context}";
  contextPath = toString context;
  inherit (context)
    adapterCommit
    debianSnapshot
    languageToolVersion
    ;
  arch = if stdenv.hostPlatform.isAarch64 then "arm64" else "amd64";
  platform = "linux-${arch}";
  podmanExe = lib.getExe podman;
  jqExe = lib.getExe jq;
in
writeShellApplication {
  name = "openclaw-languagetool-mcp-image-build";
  runtimeInputs = [
    podman
    jq
    context
  ];
  text = ''
    set -euo pipefail

    if ${podmanExe} image inspect ${lib.escapeShellArg imageName} --format json 2>/dev/null |
      ${jqExe} -e \
        --arg context ${lib.escapeShellArg contextPath} \
         --arg platform ${lib.escapeShellArg platform} \
         --arg adapterCommit ${lib.escapeShellArg adapterCommit} \
         --arg languageToolVersion ${lib.escapeShellArg languageToolVersion} \
         --arg debianSnapshot ${lib.escapeShellArg debianSnapshot} \
         --arg arch ${lib.escapeShellArg arch} \
         '.[0].Config.Labels["io.wave-os.context"] == $context and
         .[0].Config.Labels["io.wave-os.platform"] == $platform and
         .[0].Config.Labels["io.wave-os.adapter-commit"] == $adapterCommit and
         .[0].Config.Labels["io.wave-os.languagetool-version"] == $languageToolVersion and
         .[0].Config.Labels["io.wave-os.debian-snapshot"] == $debianSnapshot and
         .[0].Os == "linux" and .[0].Architecture == $arch' >/dev/null 2>&1; then
      exit 0
    fi

    exec ${podmanExe} build \
      --pull=missing \
      --platform linux/${arch} \
      --file ${lib.escapeShellArg "${contextPath}/Dockerfile"} \
      --label ${lib.escapeShellArg "io.wave-os.context=${contextPath}"} \
      --label ${lib.escapeShellArg "io.wave-os.platform=${platform}"} \
      --label ${lib.escapeShellArg "io.wave-os.adapter-commit=${adapterCommit}"} \
      --label ${lib.escapeShellArg "io.wave-os.languagetool-version=${languageToolVersion}"} \
      --label ${lib.escapeShellArg "io.wave-os.debian-snapshot=${debianSnapshot}"} \
      --tag ${lib.escapeShellArg imageName} \
      ${lib.escapeShellArg contextPath}
  '';

  passthru = {
    inherit context imageName;
  };
}
