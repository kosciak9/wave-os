{
  config,
  lib,
  pkgs,
  ...
}:

let
  caddy = pkgs.caddy.withPlugins {
    plugins = [ "github.com/caddy-dns/cloudflare@v0.2.4" ];
    hash = "sha256-xRJ5evsAJ2akg47j3Bt6YDXJOgX88B/rKNP50KSVyNY=";
  };
  caddyConfig = pkgs.writeText "Caddyfile" (builtins.readFile ./Caddyfile);
in
{
  sops = {
    secrets."cloudflare/dns-api-token" = { };
    templates."caddy-cloudflare.env" = {
      content = "CLOUDFLARE_API_TOKEN=${config.sops.placeholder."cloudflare/dns-api-token"}";
    };
  };

  system.activationScripts.preActivation.text = ''
    /usr/bin/install -d -m 0750 -o root -g wheel /var/lib/caddy
    /usr/bin/touch /var/log/caddy.log /var/log/caddy-error.log
    /usr/sbin/chown root:wheel /var/log/caddy.log /var/log/caddy-error.log
    /bin/chmod 0644 /var/log/caddy.log /var/log/caddy-error.log
  '';

  launchd.daemons.caddy = {
    serviceConfig = {
      ProgramArguments = [
        (lib.getExe caddy)
        "run"
        "--envfile"
        config.sops.templates."caddy-cloudflare.env".path
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
