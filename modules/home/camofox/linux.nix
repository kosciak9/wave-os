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
  platform = "linux-x86_64";
  platformLabel = "io.wave-os.camofox.platform";
  podman = lib.getExe pkgs.podman;
  jq = lib.getExe pkgs.jq;
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

      podman_remote() {
        local runtime_dir="''${XDG_RUNTIME_DIR:-}"
        if [[ -z "$runtime_dir" || ! -S "$runtime_dir/podman/podman.sock" ]]; then
          printf '%s\n' "Camofox: Podman user API socket unavailable at $runtime_dir/podman/podman.sock; podman.socket must be running" >&2
          return 1
        fi
        "${podman}" --remote --url "unix://$runtime_dir/podman/podman.sock" "$@"
      }

      podman_remote_exec() {
        local runtime_dir="''${XDG_RUNTIME_DIR:-}"
        if [[ -z "$runtime_dir" || ! -S "$runtime_dir/podman/podman.sock" ]]; then
          printf '%s\n' "Camofox: Podman user API socket unavailable at $runtime_dir/podman/podman.sock; podman.socket must be running" >&2
          return 1
        fi
        exec "${podman}" --remote --url "unix://$runtime_dir/podman/podman.sock" "$@"
      }

      if podman_remote image inspect ${lib.escapeShellArg image} --format json 2>/dev/null |
        ${jq} -e \
          --arg sourceLabel ${lib.escapeShellArg sourceLabel} \
          --arg platformLabel ${lib.escapeShellArg platformLabel} \
          --arg source ${lib.escapeShellArg source} \
          --arg platform ${lib.escapeShellArg platform} \
          '.[0].Config.Labels[$sourceLabel] == $source and
           .[0].Config.Labels[$platformLabel] == $platform' >/dev/null 2>&1; then
        exit 0
      fi

      podman_remote build \
        --pull=missing \
        --target camofox-browser \
        --platform linux/amd64 \
        --build-arg ARCH=x86_64 \
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
      imageBuild
    ];
    text = ''
      set -euo pipefail

      podman_remote() {
        local runtime_dir="''${XDG_RUNTIME_DIR:-}"
        if [[ -z "$runtime_dir" || ! -S "$runtime_dir/podman/podman.sock" ]]; then
          printf '%s\n' "Camofox: Podman user API socket unavailable at $runtime_dir/podman/podman.sock; podman.socket must be running" >&2
          return 1
        fi
        "${podman}" --remote --url "unix://$runtime_dir/podman/podman.sock" "$@"
      }

      podman_remote_exec() {
        local runtime_dir="''${XDG_RUNTIME_DIR:-}"
        if [[ -z "$runtime_dir" || ! -S "$runtime_dir/podman/podman.sock" ]]; then
          printf '%s\n' "Camofox: Podman user API socket unavailable at $runtime_dir/podman/podman.sock; podman.socket must be running" >&2
          return 1
        fi
        exec "${podman}" --remote --url "unix://$runtime_dir/podman/podman.sock" "$@"
      }

      state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/camofox"
      key_file="$state_dir/access-key"
      ${install} -d -m 0700 -- "$state_dir"
      if [[ ! -s "$key_file" ]]; then
        key_tmp=$(${pkgs.coreutils}/bin/mktemp "$state_dir/access-key.XXXXXX")
        trap '${pkgs.coreutils}/bin/rm -f -- "$key_tmp"' EXIT
        umask 077
        ${pkgs.coreutils}/bin/dd if=/dev/urandom bs=32 count=1 status=none |
          ${pkgs.coreutils}/bin/base64 -w 0 > "$key_tmp"
        printf '\n' >> "$key_tmp"
        ${pkgs.coreutils}/bin/chmod 0600 -- "$key_tmp"
        # Link creation is atomic and never overwrites a key another service
        # instance may have created concurrently.  The EXIT trap removes the
        # temporary file both when we lose that race and on other failures.
        if ! ${pkgs.coreutils}/bin/ln -- "$key_tmp" "$key_file" 2>/dev/null; then
          [[ -s "$key_file" ]] || exit 1
        fi
        ${pkgs.coreutils}/bin/rm -f -- "$key_tmp"
        trap - EXIT
      fi
      access_key=$(${pkgs.coreutils}/bin/cat -- "$key_file")
      [[ -n "$access_key" ]] || { printf '%s\n' "refusing to start Camofox: access key is empty" >&2; exit 1; }
      export CAMOFOX_ACCESS_KEY="$access_key"
      unset CAMOFOX_API_KEY

      if ! info=$(podman_remote info --format json); then
        printf '%s\n' "refusing to start Camofox: rootless Podman user API info failed" >&2
        exit 1
      fi
      if ! ${jq} -e '.host.security.rootless == true' <<<"$info" >/dev/null 2>&1; then
        printf '%s\n' "refusing to start Camofox: local Podman reported a non-rootless configuration" >&2
        exit 1
      fi

      ${lib.getExe imageBuild}
      podman_remote network inspect camofox-browser >/dev/null 2>&1 ||
        podman_remote network create --driver bridge camofox-browser >/dev/null 2>&1 ||
        podman_remote network inspect camofox-browser >/dev/null 2>&1
      podman_remote rm --force camofox-browser >/dev/null 2>&1 || true

      # Blanket capability removal breaks Firefox's sandbox; these drops remain confined to the rootless user namespace.
      podman_remote_exec run --rm \
         --name camofox-browser \
         --init \
         --network camofox-browser \
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

  systemd.user.services.camofox-browser = {
    Unit = {
      Description = "Local Camofox browser server";
      Wants = [ "podman.socket" ];
      After = [ "podman.socket" ];
    };
    Service = {
      Type = "simple";
      ExecStart = lib.getExe camofoxAgent;
      Restart = "always";
      RestartSec = 10;
      UMask = "0077";
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
      ];
      StandardOutput = "append:${homeDirectory}/.camofox/logs/systemd.log";
      StandardError = "append:${homeDirectory}/.camofox/logs/systemd.error.log";
    };
    Install.WantedBy = [ "default.target" ];
  };
}
