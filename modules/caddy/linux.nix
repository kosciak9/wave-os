_:

let
  developmentRootCa = ./development-root-ca.crt;
in
{
  security.pki.certificateFiles = [ developmentRootCa ];

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
      "development-root-ca.key:/home/kosciak/.config/secrets/development-ca/root.key"
    ];
  };
}
