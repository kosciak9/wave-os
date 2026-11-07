{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.wave;
  ip = lib.getExe' pkgs.iproute2 "ip";
  # GitHub token for commit statuses, provisioned outside the repository; empty disables them.
  tokenFile = "/var/lib/wave-os/github-token";
in
{
  imports = [ ./common.nix ];

  options.wave.autoDeploy = {
    enable = lib.mkEnableOption "deploying latest main from a timer once CI passes: this host first, then `nodes`";
    nodes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Deploy nodes updated after this host, in parallel.";
    };
    interval = lib.mkOption {
      type = lib.types.str;
      default = "5min";
      description = "Pause between runs.";
    };
  };

  config = lib.mkMerge [
    {
      wave = {
        deployTarget.authorizedKeysDirectory = "/var/lib/wave-os/ssh";
        health.checks = {
          network = ''
            [[ -n "$(${ip} -4 route show default)" || -n "$(${ip} -6 route show default)" ]]
          '';
          dns = ''
            ${lib.getExe' pkgs.getent "getent"} ahosts example.com >/dev/null
          '';
        };
      };

      nix = {
        gc = {
          automatic = true;
          dates = "weekly";
          options = "--delete-older-than 14d";
          persistent = true;
        };
        optimise.automatic = true;
      };

      # Hosts open Mosh's UDP range (60000-61000) next to SSH on their own interfaces.
      programs.mosh = {
        enable = true;
        openFirewall = false;
      };

      systemd.tmpfiles.rules = [
        "d /var/lib/wave-os 0755 root root - -"
        "d /var/lib/wave-os/source 0700 kosciak ${config.users.users.kosciak.group} - -"
        "d /var/lib/wave-os/state 0755 root root - -"
        "d /var/lib/wave-os/state/cli 0700 kosciak ${config.users.users.kosciak.group} - -"
      ];
    }

    (lib.mkIf cfg.deployTarget.enable {
      users = {
        groups.deploy = { };
        users.deploy = {
          isSystemUser = true;
          group = "deploy";
          description = "Wave deployment";
          shell = pkgs.bashInteractive;
        };
      };
      security.sudo.extraRules = [
        {
          users = [ "deploy" ];
          commands = [
            {
              command = "ALL";
              options = [ "NOPASSWD" ];
            }
          ];
        }
      ];
      nix.settings.trusted-users = [ "deploy" ];
      services.openssh.authorizedKeysFiles = [ "${cfg.deployTarget.authorizedKeysDirectory}/%u" ];
      systemd.tmpfiles.rules = [
        "d ${cfg.deployTarget.authorizedKeysDirectory} 0755 root root - -"
        "f ${cfg.deployTarget.authorizedKeysDirectory}/deploy 0644 root root - -"
      ];
    })

    (lib.mkIf cfg.autoDeploy.enable {
      assertions = [
        {
          assertion = cfg.autoDeploy.nodes == [ ] || cfg.deployer.enable;
          message = "wave.autoDeploy.nodes requires wave.deployer.enable";
        }
      ];
      systemd = {
        tmpfiles.rules = [ "f ${tokenFile} 0600 root root - -" ];
        services.wave-autodeploy = {
          description = "Deploy latest main once CI passes";
          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];
          # The service activates this host itself; a restart would cut the switch short.
          restartIfChanged = false;
          serviceConfig = {
            Type = "oneshot";
            User = "kosciak";
            ExecStart = lib.escapeShellArgs (
              [
                (lib.getExe pkgs.wave)
                "autodeploy"
              ]
              ++ cfg.autoDeploy.nodes
            );
            LoadCredential = "github-token:${tokenFile}";
          };
        };
        timers.wave-autodeploy = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "5min";
            OnUnitInactiveSec = cfg.autoDeploy.interval;
          };
        };
      };
    })
  ];
}
