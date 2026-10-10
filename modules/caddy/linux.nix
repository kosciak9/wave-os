{ config, ... }:

let
  developmentRootCa = ./development-root-ca.crt;
in
{
  security.pki.certificateFiles = [ developmentRootCa ];
  sops.secrets.development-ca-key.restartUnits = [ "caddy.service" ];

  services.caddy = {
    enable = true;
    configFile = ./Caddyfile;
  };

  systemd.services.caddy = {
    environment = {
      WAVE_DEVELOPMENT_CA_CERT = "%d/development-root-ca.crt";
      WAVE_DEVELOPMENT_CA_KEY = "%d/development-root-ca.key";
    };
    serviceConfig.LoadCredential = [
      "development-root-ca.crt:${developmentRootCa}"
      "development-root-ca.key:${config.sops.secrets.development-ca-key.path}"
    ];
  };
}
