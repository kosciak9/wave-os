{
  config,
  lib,
  pkgs,
  ...
}:

let
  homeDirectory = config.home.homeDirectory;
  podman = lib.getExe pkgs.podman;
  jq = lib.getExe pkgs.jq;
  install = lib.getExe' pkgs.coreutils "install";
  podmanRemoteFunctions = ''
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
  '';
  common = import ./common.nix {
    inherit config lib pkgs;
    platform = "linux-x86_64";
    buildPlatform = "linux/amd64";
    buildArch = "x86_64";
    transport = "podman_remote";
    transportExec = "podman_remote_exec";
    imageBuildPrelude = podmanRemoteFunctions;
  };
  camofoxAgent = pkgs.writeShellApplication {
    name = "camofox-browser-agent";
    runtimeInputs = [
      pkgs.podman
      pkgs.jq
      pkgs.coreutils
      common.imageBuild
    ];
    text = ''
            set -euo pipefail
            ${podmanRemoteFunctions}

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

            ${lib.getExe common.imageBuild}
            podman_remote network inspect camofox-browser >/dev/null 2>&1 ||
              podman_remote network create --driver bridge camofox-browser >/dev/null 2>&1 ||
              podman_remote network inspect camofox-browser >/dev/null 2>&1
            podman_remote rm --force camofox-browser >/dev/null 2>&1 || true

            # Blanket capability removal breaks Firefox's sandbox; these drops remain confined to the rootless user namespace.
            podman_remote_exec run --rm \
               --name camofox-browser \
               --init \
               --network camofox-browser \
      ${common.commonRunArgs}
    '';
  };
in
{
  home.packages = [ common.imageBuild ];
  home.activation.camofoxDirectories = common.activation;
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
