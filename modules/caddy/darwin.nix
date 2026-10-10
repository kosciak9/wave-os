{ lib, pkgs, ... }:

let
  caddyConfig = pkgs.writeText "Caddyfile" (builtins.readFile ./Caddyfile);
in
{
  system.activationScripts.preActivation.text = ''
    /usr/bin/install -d -m 0750 -o root -g wheel /var/lib/caddy
    /usr/bin/touch /var/log/caddy.log /var/log/caddy-error.log
    /usr/sbin/chown root:wheel /var/log/caddy.log /var/log/caddy-error.log
    /bin/chmod 0644 /var/log/caddy.log /var/log/caddy-error.log
  '';

  launchd.daemons.caddy = {
    serviceConfig = {
      ProgramArguments = [
        (lib.getExe pkgs.caddy)
        "run"
        "--config"
        "${caddyConfig}"
        "--adapter"
        "caddyfile"
      ];
      EnvironmentVariables = {
        HOME = "/var/lib/caddy";
        XDG_CONFIG_HOME = "/var/lib/caddy/config";
        XDG_DATA_HOME = "/var/lib/caddy";
      };
      RunAtLoad = true;
      KeepAlive = true;
      ProcessType = "Background";
      StandardErrorPath = "/var/log/caddy-error.log";
      StandardOutPath = "/var/log/caddy.log";
      ThrottleInterval = 5;
      WorkingDirectory = "/var/lib/caddy";
    };
  };
}
