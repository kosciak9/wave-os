{
  context,
  jq,
  lib,
  podman,
  writeShellApplication,
}:

let
  imageName = "localhost/wave-os/openclaw-languagetool-mcp:${lib.getVersion context}";
  contextPath = toString context;
  inherit (context)
    adapterCommit
    debianSnapshot
    languageToolVersion
    platform
    ;
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

    deadline=$((SECONDS + 180))
    while ! info=$(${podmanExe} --connection openclaw-sandbox info --format json 2>/dev/null) ||
      ! printf '%s\n' "$info" | ${jqExe} -e '.host.security.rootless == true' >/dev/null 2>&1; do
      if (( SECONDS >= deadline )); then
        printf '%s\n' "openclaw-sandbox was not reachable as a rootless Podman connection within 180 seconds" >&2
        exit 1
      fi
      sleep 2
    done

    if ${podmanExe} --connection openclaw-sandbox image inspect ${lib.escapeShellArg imageName} --format json 2>/dev/null |
      ${jqExe} -e \
        --arg context ${lib.escapeShellArg contextPath} \
         --arg platform ${lib.escapeShellArg platform} \
         --arg adapterCommit ${lib.escapeShellArg adapterCommit} \
         --arg languageToolVersion ${lib.escapeShellArg languageToolVersion} \
         --arg debianSnapshot ${lib.escapeShellArg debianSnapshot} \
         '.[0].Config.Labels["io.wave-os.context"] == $context and
         .[0].Config.Labels["io.wave-os.platform"] == $platform and
         .[0].Config.Labels["io.wave-os.adapter-commit"] == $adapterCommit and
         .[0].Config.Labels["io.wave-os.languagetool-version"] == $languageToolVersion and
         .[0].Config.Labels["io.wave-os.debian-snapshot"] == $debianSnapshot and
         .[0].Os == "linux" and .[0].Architecture == "arm64"' >/dev/null 2>&1; then
      exit 0
    fi

    exec ${podmanExe} --connection openclaw-sandbox build \
      --pull=missing \
      --platform linux/arm64 \
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
