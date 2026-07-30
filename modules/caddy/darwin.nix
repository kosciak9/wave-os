{ lib, pkgs, ... }:

let
  developmentRootCa = ./development-root-ca.crt;
  caddyConfig = pkgs.writeText "Caddyfile" (builtins.readFile ./Caddyfile);
in
{
  security.pki.certificateFiles = [ developmentRootCa ];

  system.activationScripts.preActivation.text = ''
    /usr/bin/install -d -m 0750 -o root -g wheel /var/lib/caddy
    /usr/bin/touch /var/log/caddy.log /var/log/caddy-error.log
    /usr/sbin/chown root:wheel /var/log/caddy.log /var/log/caddy-error.log
    /bin/chmod 0644 /var/log/caddy.log /var/log/caddy-error.log
  '';

  system.activationScripts.postActivation.text = ''
    if ! /usr/bin/security find-certificate -a -Z /Library/Keychains/System.keychain \
      | /usr/bin/grep -q '18A688AC071A5A192EA781D03635E31D9E001C72F2739102124B56323C8EFDA2'; then
      /usr/bin/security add-trusted-cert -d -r trustRoot \
        -k /Library/Keychains/System.keychain \
        ${developmentRootCa}
    fi
  '';

  launchd.daemons.caddy.serviceConfig = {
    EnvironmentVariables = {
      HOME = "/var/lib/caddy";
      WAVE_DEVELOPMENT_CA_CERT = toString developmentRootCa;
      WAVE_DEVELOPMENT_CA_KEY = "/Users/kosciak/.config/secrets/development-ca/root.key";
      XDG_CONFIG_HOME = "/var/lib/caddy/config";
      XDG_DATA_HOME = "/var/lib/caddy";
    };
    ProgramArguments = [
      (lib.getExe pkgs.caddy)
      "run"
      "--config"
      (toString caddyConfig)
      "--adapter"
      "caddyfile"
    ];
    RunAtLoad = true;
    KeepAlive = true;
    ProcessType = "Background";
    StandardErrorPath = "/var/log/caddy-error.log";
    StandardOutPath = "/var/log/caddy.log";
    ThrottleInterval = 5;
    WorkingDirectory = "/var/lib/caddy";
  };
}
