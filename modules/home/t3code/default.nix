{
  config,
  lib,
  pkgs,
  ...
}:
let
  logDirectory = "${config.home.homeDirectory}/Library/Logs/T3Code";
  theme = pkgs.writeText "kanagawa-dragon.json" (builtins.toJSON (import ./kanagawa-dragon.nix));
  arguments = [
    (lib.getExe pkgs.t3code-cli)
    "serve"
    "--host"
    "127.0.0.1"
    "--port"
    "3773"
    "--tailscale-serve"
    "--tailscale-serve-port"
    "18443"
  ];
  environment = {
    HOME = config.home.homeDirectory;
    T3CODE_HOME = "${config.home.homeDirectory}/.t3";
    PATH = "${config.home.path}/bin:${
      lib.makeBinPath [ pkgs.tailscale ]
    }:/run/current-system/sw/bin:/usr/bin:/bin:/usr/sbin:/sbin";
  };
in
{
  home = {
    packages = [ pkgs.t3code-cli ];
    activation = {
      t3codeTheme = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
        run ${lib.getExe pkgs.t3code-cli} theme set --base-dir ${lib.escapeShellArg environment.T3CODE_HOME} \
          --id kanagawa-dragon ${theme}
      '';
      t3codeLogDirectory = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin (
        lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          ${lib.getExe' pkgs.coreutils "install"} -d -m 0700 -- ${lib.escapeShellArg logDirectory}
        ''
      );
    };
  };

  systemd.user.services.t3code = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
    Unit = {
      Description = "T3 Code agent server";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
    };
    Service = {
      ExecStart = lib.escapeShellArgs arguments;
      Environment = lib.mapAttrsToList (name: value: "${name}=${value}") environment;
      WorkingDirectory = config.home.homeDirectory;
      Restart = "on-failure";
      RestartSec = 10;
      KillMode = "mixed";
      TimeoutStopSec = 30;
      UMask = "0077";
      # Headless startup prints a one-time pairing credential to stdout.
      StandardOutput = "null";
    };
    Install.WantedBy = [ "default.target" ];
  };

  launchd.agents.t3code = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
    enable = true;
    domain = "gui";
    config = {
      ProgramArguments = arguments;
      EnvironmentVariables = environment;
      WorkingDirectory = config.home.homeDirectory;
      RunAtLoad = true;
      KeepAlive = true;
      ThrottleInterval = 10;
      ProcessType = "Background";
      Umask = 63;
      StandardOutPath = "/dev/null";
      StandardErrorPath = "${logDirectory}/server.error.log";
    };
  };
}
