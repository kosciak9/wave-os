{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.fugate;
  stateDirectory = "${config.home.homeDirectory}/.local/state/fugate";
  configFile = pkgs.writeText "fugate.json" (
    builtins.toJSON {
      inherit (cfg) bind port;
      max_concurrent = cfg.maxConcurrent;
      allowed_clients = cfg.allowedClients;
      hosts = lib.mapAttrs (_name: host: {
        herdr_alias = host.herdrAlias;
        inherit (host) harnesses;
        max_concurrent = host.maxConcurrent;
      }) cfg.hosts;
    }
  );
in
{
  options.services.fugate = {
    enable = lib.mkEnableOption "the Fugate unattended agent scheduler";
    package = lib.mkPackageOption pkgs "fugate" { };
    port = lib.mkOption {
      type = lib.types.port;
      default = 4747;
      description = "HTTP port of the JSON:API, MCP and health endpoints.";
    };
    bind = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
      description = "Listen address; non-loopback callers must be allowed tailnet clients.";
    };
    maxConcurrent = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = "Runs occupying a host at once, across all hosts.";
    };
    allowedClients = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "ahri" ];
      description = "Tailscale host names allowed to use the API besides loopback.";
    };
    hosts = lib.mkOption {
      description = "Execution hosts reachable through the local Herdr daemon.";
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            herdrAlias = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Herdr saved-machine alias; null for the local Herdr.";
            };
            harnesses = lib.mkOption {
              type = lib.types.listOf (
                lib.types.enum [
                  "claude"
                  "codex"
                  "opencode"
                ]
              );
              description = "Agent harnesses the host can run.";
            };
            maxConcurrent = lib.mkOption {
              type = lib.types.ints.positive;
              default = 1;
              description = "Runs occupying this host at once.";
            };
          };
        }
      );
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.isDarwin;
        message = "Fugate launchd supervision requires Darwin.";
      }
      {
        assertion = cfg.hosts != { };
        message = "services.fugate.hosts must configure at least one execution host.";
      }
    ];
    home.activation.fugateState = lib.hm.dag.entryBetween [ "setupLaunchAgents" ] [ "writeBoundary" ] ''
      run mkdir -p ${lib.escapeShellArg "${stateDirectory}/tmp"}
      run chmod 0700 ${lib.escapeShellArg stateDirectory}
    '';
    launchd.agents.fugate = {
      enable = true;
      domain = "user";
      config = {
        ProgramArguments = [
          (lib.getExe cfg.package)
          "start"
        ];
        EnvironmentVariables = {
          HOME = config.home.homeDirectory;
          # Includes tailscale, used to identify tailnet API clients.
          PATH = "/run/current-system/sw/bin:/usr/bin:/bin:/usr/sbin:/sbin";
          RELEASE_DISTRIBUTION = "none";
          # Distribution is off, so the cookie never authenticates anything.
          RELEASE_COOKIE = "fugate";
          RELEASE_TMP = "${stateDirectory}/tmp";
          FUGATE_DATABASE = "${stateDirectory}/fugate.db";
          FUGATE_CONFIG = toString configFile;
          HERDR_SOCKET_PATH = "${config.xdg.configHome}/herdr/herdr.sock";
        };
        RunAtLoad = true;
        KeepAlive = true;
        ProcessType = "Background";
        ThrottleInterval = 10;
        ExitTimeOut = 30;
        Umask = 63;
        StandardOutPath = "${stateDirectory}/launchd.log";
        StandardErrorPath = "${stateDirectory}/launchd.error.log";
      };
    };
  };
}
