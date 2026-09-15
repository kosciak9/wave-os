{
  config,
  lib,
  pkgs,
  platform,
  buildPlatform,
  buildArch,
  transport,
  transportExec,
  imageBuildPrelude ? "",
}:

let
  homeDirectory = config.home.homeDirectory;
  camofoxVersion = pkgs.camofox-browser-source.version;
  image = "localhost/wave-os/camofox-browser:${camofoxVersion}";
  source = toString pkgs.camofox-browser-source;
  sourceLabel = "io.wave-os.camofox.source";
  platformLabel = "io.wave-os.camofox.platform";
  install = lib.getExe' pkgs.coreutils "install";
  imageBuild = pkgs.writeShellApplication {
    name = "camofox-browser-image-build";
    runtimeInputs = [
      pkgs.podman
      pkgs.jq
      pkgs.coreutils
    ];
    text = ''
      set -euo pipefail
      ${imageBuildPrelude}

      if ${transport} image inspect ${lib.escapeShellArg image} --format json 2>/dev/null |
        ${lib.getExe pkgs.jq} -e \
          --arg sourceLabel ${lib.escapeShellArg sourceLabel} \
          --arg platformLabel ${lib.escapeShellArg platformLabel} \
          --arg source ${lib.escapeShellArg source} \
          --arg platform ${lib.escapeShellArg platform} \
          '.[0].Config.Labels[$sourceLabel] == $source and
           .[0].Config.Labels[$platformLabel] == $platform' >/dev/null 2>&1; then
        exit 0
      fi

      ${transportExec} build \
        --pull=missing \
        --target camofox-browser \
        --platform ${lib.escapeShellArg buildPlatform} \
        --build-arg ${lib.escapeShellArg "ARCH=${buildArch}"} \
        --file ${lib.escapeShellArg "${source}/Dockerfile"} \
        --label ${lib.escapeShellArg "${sourceLabel}=${source}"} \
        --label ${lib.escapeShellArg "${platformLabel}=${platform}"} \
        --tag ${lib.escapeShellArg image} \
        ${lib.escapeShellArg source}
    '';
  };
  commonRunArgs = ''
    --pull=never \
    --publish 127.0.0.1:9377:9377 \
    --cap-drop AUDIT_WRITE \
    --cap-drop MKNOD \
    --cap-drop NET_RAW \
    --cap-drop NET_BIND_SERVICE \
    --security-opt no-new-privileges \
    --pids-limit 512 \
    --shm-size 2g \
    --mount type=bind,src=${lib.escapeShellArg "${homeDirectory}/.camofox/profiles"},dst=/home/node/.camofox/profiles,relabel=private \
    --mount type=bind,src=${lib.escapeShellArg "${homeDirectory}/.camofox/traces"},dst=/home/node/.camofox/traces,relabel=private \
    --mount type=bind,src=${lib.escapeShellArg "${homeDirectory}/.camofox/uploads"},dst=/home/node/.camofox/uploads,readonly,relabel=private \
    --mount type=bind,src=${lib.escapeShellArg "${homeDirectory}/.camofox/cookies"},dst=/home/node/.camofox/cookies,readonly,relabel=private \
    --env CAMOFOX_ACCESS_KEY \
    --env CAMOFOX_PORT=9377 \
    --env CAMOFOX_BIND_HOST=0.0.0.0 \
    --env CAMOFOX_INTERACTIVE=off \
    --env PROXY_HOST=127.0.0.1 \
    --env PROXY_PORT=3128 \
    --env PROXY_STRATEGY=round_robin \
    --env NODE_ENV=production \
    --env CAMOFOX_PROFILE_DIR=/home/node/.camofox/profiles \
    --env CAMOFOX_TRACES_DIR=/home/node/.camofox/traces \
    --env CAMOFOX_UPLOADS_DIR=/home/node/.camofox/uploads \
    --env CAMOFOX_COOKIES_DIR=/home/node/.camofox/cookies \
    --env MAX_SESSIONS=5 \
    --env MAX_TABS_PER_SESSION=3 \
    --env SESSION_TIMEOUT_MS=600000 \
    --env BROWSER_IDLE_TIMEOUT_MS=300000 \
    --env TAB_INACTIVITY_MS=300000 \
    --env CAMOFOX_CRASH_REPORT_ENABLED=false \
    --env CAMOFOX_DISABLE_DEFAULT_ADDONS=true \
    ${lib.escapeShellArg image}
  '';
in
{
  inherit imageBuild commonRunArgs;
  activation = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    ${install} -d -m 0700 -- \
      "${homeDirectory}/.camofox" \
      "${homeDirectory}/.camofox/profiles" \
      "${homeDirectory}/.camofox/traces" \
      "${homeDirectory}/.camofox/uploads" \
      "${homeDirectory}/.camofox/cookies" \
      "${homeDirectory}/.camofox/logs"
    ${pkgs.coreutils}/bin/chmod 0700 -- \
      "${homeDirectory}/.camofox" \
      "${homeDirectory}/.camofox/profiles" \
      "${homeDirectory}/.camofox/traces" \
      "${homeDirectory}/.camofox/uploads" \
      "${homeDirectory}/.camofox/cookies" \
      "${homeDirectory}/.camofox/logs"
  '';
}
