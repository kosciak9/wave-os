{
  config,
  lib,
  pkgs,
  ...
}:

let
  homeDirectory = config.home.homeDirectory;
  camofoxVersion = "1.15.0";
  image = "localhost/wave-os/camofox-browser:${camofoxVersion}";
  source = toString pkgs.camofox-browser-source;
  sourceLabel = "io.wave-os.camofox.source";
  platform = "linux-arm64";
  platformLabel = "io.wave-os.camofox.platform";
  podman = lib.getExe pkgs.podman;
  jq = lib.getExe pkgs.jq;
  openclaw = lib.getExe config.programs.openclaw.package;
  install = lib.getExe' pkgs.coreutils "install";

  rootlessConnectionCheck = ''
    deadline=$((SECONDS + 180))
    while ! info=$(${podman} --connection openclaw-sandbox info --format json 2>/dev/null) ||
      ! printf '%s\n' "$info" | ${jq} -e '.host.security.rootless == true' >/dev/null 2>&1; do
      if (( SECONDS >= deadline )); then
        printf '%s\n' "openclaw-sandbox was not reachable as a rootless Podman connection within 180 seconds" >&2
        exit 1
      fi
      sleep 2
    done
  '';

  imageBuild = pkgs.writeShellApplication {
    name = "camofox-browser-image-build";
    runtimeInputs = [
      pkgs.podman
      pkgs.jq
      pkgs.coreutils
    ];
    text = ''
      set -euo pipefail
      ${rootlessConnectionCheck}

      if ${podman} --connection openclaw-sandbox image inspect ${lib.escapeShellArg image} --format json 2>/dev/null |
        ${jq} -e \
          --arg sourceLabel ${lib.escapeShellArg sourceLabel} \
          --arg platformLabel ${lib.escapeShellArg platformLabel} \
          --arg source ${lib.escapeShellArg source} \
          --arg platform ${lib.escapeShellArg platform} \
          '.[0].Config.Labels[$sourceLabel] == $source and
           .[0].Config.Labels[$platformLabel] == $platform' >/dev/null 2>&1; then
        exit 0
      fi

      exec ${podman} --connection openclaw-sandbox build \
        --pull=missing \
        --target camofox-browser \
        --platform linux/arm64 \
        --build-arg ARCH=arm64 \
        --file ${lib.escapeShellArg "${source}/Dockerfile"} \
        --label ${lib.escapeShellArg "${sourceLabel}=${source}"} \
        --label ${lib.escapeShellArg "${platformLabel}=${platform}"} \
        --tag ${lib.escapeShellArg image} \
        ${lib.escapeShellArg source}
    '';
  };

  camofoxAgent = pkgs.writeShellApplication {
    name = "camofox-browser-agent";
    runtimeInputs = [
      pkgs.podman
      pkgs.jq
      pkgs.coreutils
      config.programs.openclaw.package
    ];
    text = ''
      set -euo pipefail
      openclaw=${lib.escapeShellArg openclaw}
      image_build=${lib.escapeShellArg (lib.getExe imageBuild)}

      if ! access_key=$("$openclaw" secrets store get CAMOFOX_ACCESS_KEY --plain 2>/dev/null); then
        printf '%s\n' "refusing to start Camofox: could not retrieve CAMOFOX_ACCESS_KEY from the OpenClaw Secret Store" >&2
        exit 1
      fi
      if [[ -z "$access_key" ]]; then
        printf '%s\n' "refusing to start Camofox: CAMOFOX_ACCESS_KEY is empty" >&2
        exit 1
      fi
      export CAMOFOX_ACCESS_KEY="$access_key"
      unset CAMOFOX_API_KEY

      ${rootlessConnectionCheck}
      "$image_build"

      ${podman} --connection openclaw-sandbox network inspect openclaw-camofox >/dev/null 2>&1 ||
        ${podman} --connection openclaw-sandbox network create --driver bridge openclaw-camofox >/dev/null
      ${podman} --connection openclaw-sandbox rm --force openclaw-camofox-browser >/dev/null 2>&1 || true

      # Blanket capability removal breaks Firefox's sandbox; these drops remain confined to the rootless user namespace.
      exec ${podman} --connection openclaw-sandbox run --rm \
         --name openclaw-camofox-browser \
         --init \
         --network openclaw-camofox \
        --pull=never \
        --publish 127.0.0.1:9377:9377 \
        --cap-drop AUDIT_WRITE \
        --cap-drop MKNOD \
        --cap-drop NET_RAW \
        --cap-drop NET_BIND_SERVICE \
        --security-opt no-new-privileges \
        --pids-limit 512 \
        --memory 2g \
        --cpus 2 \
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
  };
in
{
  assertions = [
    {
      assertion = lib.getVersion pkgs.camofox-browser-source == camofoxVersion;
      message = "Camofox Browser must be exactly 1.15.0";
    }
  ];

  home.packages = [ imageBuild ];

  home.activation.camofoxDirectories = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
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

  launchd.agents.camofox-browser = {
    enable = true;
    domain = "gui";
    config = {
      ProgramArguments = [ (lib.getExe camofoxAgent) ];
      RunAtLoad = true;
      KeepAlive = true;
      ProcessType = "Background";
      Umask = 63;
      ThrottleInterval = 10;
      StandardOutPath = "${homeDirectory}/.camofox/logs/launchd.log";
      StandardErrorPath = "${homeDirectory}/.camofox/logs/launchd.error.log";
    };
  };
}
