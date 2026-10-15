{
  config,
  osConfig,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.fugate;
  localHost = osConfig.networking.hostName;
  savedMachines = config.programs.herdr.federation.savedMachines;
  # Every execution host gets all harnesses from the shared herdr and opencode modules.
  harnesses = [
    "claude"
    "codex"
    "opencode"
  ];
  stateDirectory = "${config.home.homeDirectory}/.local/state/fugate";
  configFile = pkgs.writeText "fugate.json" (
    builtins.toJSON {
      inherit (cfg) bind port;
      max_concurrent = cfg.maxConcurrent;
      allowed_clients = cfg.allowedClients;
      hosts = lib.genAttrs cfg.hosts (host: {
        herdr_alias = if host == localHost then null else savedMachines.${host}.profileId;
        inherit harnesses;
        max_concurrent = cfg.maxConcurrentPerHost;
      });
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
      type = lib.types.listOf lib.types.str;
      description = "Execution hosts: this host or Herdr saved machines.";
    };
    maxConcurrentPerHost = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
      description = "Runs occupying one host at once.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.isDarwin;
        message = "Fugate launchd supervision requires Darwin.";
      }
      {
        assertion = cfg.hosts != [ ];
        message = "services.fugate.hosts must list at least one execution host.";
      }
      {
        assertion = lib.all (host: host == localHost || savedMachines ? ${host}) cfg.hosts;
        message = "services.fugate.hosts must be ${localHost} or programs.herdr.federation.savedMachines entries.";
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
