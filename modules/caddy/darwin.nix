{ lib, pkgs, ... }:

let
  developmentRootCa = ./development-root-ca.crt;
  caddyConfig = pkgs.writeText "Caddyfile" (builtins.readFile ./Caddyfile);
  # Remove expired local leaf assets before Caddy loads them, avoiding caddyserver/caddy#4776's cleanup/renewal race after long downtime.
  caddyRunner = pkgs.writeShellApplication {
    name = "wave-caddy-run";
    runtimeInputs = with pkgs; [
      caddy
      coreutils
      openssl
    ];
    text = ''
      certificatesDirectory=/var/lib/caddy/caddy/certificates/local
      shopt -s nullglob

      if ! certificatesRoot=$(realpath -e "$certificatesDirectory"); then
        printf 'Skipping local certificate scan; root is unavailable: %s\n' "$certificatesDirectory"
      else
        for certificate in "$certificatesDirectory"/*/*.crt; do
          if [[ ! -f "$certificate" || -L "$certificate" ]]; then
            printf 'Skipping unexpected local certificate path: %s\n' "$certificate"
            continue
          fi

          certificateName=''${certificate##*/}
          certificateStem=''${certificateName%.crt}
          certificateDirectory=''${certificate%/*}
          certificateDirectoryName=''${certificateDirectory##*/}
          if [[ "$certificateStem" != "$certificateDirectoryName" ]]; then
            printf 'Skipping unexpected local certificate path: %s\n' "$certificate"
            continue
          fi

          if ! resolvedCertificateDirectory=$(realpath -e "$certificateDirectory"); then
            printf 'Skipping local certificate path; parent is unavailable: %s\n' "$certificate"
            continue
          fi
          resolvedParent=''${resolvedCertificateDirectory%/*}
          resolvedDirectoryName=''${resolvedCertificateDirectory##*/}
          if [[ "$resolvedParent" != "$certificatesRoot" || "$resolvedDirectoryName" != "$certificateStem" ]]; then
            printf 'Skipping unexpected local certificate path: %s\n' "$certificate"
            continue
          fi

          if ! openssl x509 -in "$certificate" -noout >/dev/null 2>&1; then
            printf 'Skipping invalid local certificate: %s\n' "$certificate"
            continue
          fi

          if openssl x509 -in "$certificate" -checkend 0 -noout >/dev/null 2>&1; then
            continue
          fi

          key="''${certificate%.crt}.key"
          metadata="''${certificate%.crt}.json"
          rm -f -- "$certificate" "$key" "$metadata"
          printf 'Removed expired local certificate files: %s, %s, %s\n' \
            "$certificate" "$key" "$metadata"
        done
      fi

      exec ${lib.getExe pkgs.caddy} run --config ${lib.escapeShellArg (toString caddyConfig)} --adapter caddyfile
    '';
  };
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
      WAVE_DEVELOPMENT_CA_CERT = "${developmentRootCa}";
      WAVE_DEVELOPMENT_CA_KEY = "/Users/kosciak/.config/secrets/development-ca/root.key";
      XDG_CONFIG_HOME = "/var/lib/caddy/config";
      XDG_DATA_HOME = "/var/lib/caddy";
    };
    ProgramArguments = [
      (lib.getExe caddyRunner)
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
