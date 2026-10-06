{
  config,
  lib,
  pkgs,
  waveRevision,
  ...
}:
let
  cfg = config.wave;
  curl = lib.getExe pkgs.curl;
  jq = lib.getExe pkgs.jq;
  probes = lib.mapAttrs (
    name: command:
    pkgs.writeShellScript "wave-health-${name}" ''
      set -euo pipefail
      ${command}
    ''
  ) cfg.health.checks;
in
{
  options.wave = {
    health = {
      checks = lib.mkOption {
        type = lib.types.attrsOf lib.types.lines;
        default = { };
        description = "Named shell probes of host health; a probe is healthy when it exits 0.";
      };
      manifest = lib.mkOption {
        type = lib.types.package;
        readOnly = true;
        description = "Store file listing the probe executables of this system.";
      };
    };

    deployer.enable = lib.mkEnableOption "deploying other hosts as their `deploy` user with ~/.ssh/wave-deploy";

    deployTarget = {
      enable = lib.mkEnableOption "the passwordless `deploy` user that deploy-rs connects as";
      authorizedKeysDirectory = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        description = "Root-owned directory with per-user authorized keys, provisioned outside the repository.";
      };
    };
  };

  config = {
    wave.health = {
      manifest = pkgs.writeText "wave-health.json" (
        builtins.toJSON { checks = lib.mapAttrs (_: toString) probes; }
      );
      checks = {
        https = ''
          for url in https://www.cloudflare.com/cdn-cgi/trace https://www.google.com/generate_204; do
            ${curl} -q -sSf --proto =https --max-time 3 --output /dev/null "$url" && exit 0
          done
          exit 1
        '';
      }
      // lib.optionalAttrs config.services.tailscale.enable {
        tailscale = ''
          ${lib.getExe config.services.tailscale.package} status --json \
            | ${jq} -e '.BackendState == "Running" and ((.Health // []) | length == 0)' >/dev/null
        '';
      }
      // lib.optionalAttrs config.services.openssh.enable {
        ssh = ''
          banner=$(${lib.getExe' pkgs.coreutils "timeout"} 2 ${lib.getExe pkgs.bash} -c \
            'exec 3<>/dev/tcp/127.0.0.1/22 && IFS= read -r line <&3 && printf %s "$line"')
          [[ $banner == SSH-2.0-* || $banner == SSH-1.99-* ]]
        '';
      };
    };

    programs.ssh.extraConfig = lib.mkIf cfg.deployer.enable ''
      Match user deploy
        IdentityFile ~/.ssh/wave-deploy
        IdentitiesOnly yes
    '';

    environment.systemPackages = [ pkgs.wave ];
    environment.etc = {
      "wave-os/revision".text = "${waveRevision}\n";
      "wave-os/health.json".source = cfg.health.manifest;
    };
  };
}
