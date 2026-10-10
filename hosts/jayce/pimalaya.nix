{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:

let
  pimalaya = pkgs.callPackage ../../packages/pimalaya.nix { };
  toml = pkgs.formats.toml { };
  jq = lib.getExe pkgs.jq;

  # Google accounts synced into their own pimdir store; the first is the default.
  accounts = [
    "work"
    "personal"
  ];
  googleClient = osConfig.sops.secrets."pimalaya/google-client.json".path;
  tokenDirectory = "${config.xdg.stateHome}/pimalaya/tokens";
  storeRoot = account: "${config.xdg.stateHome}/neverest/${account}";
  forAccounts =
    settings:
    lib.listToAttrs (
      lib.imap0 (index: account: {
        name = account;
        value = {
          default = index == 0;
        }
        // settings account;
      }) accounts
    );

  ortieConfig = toml.generate "ortie.toml" {
    accounts = forAccounts (account: {
      endpoints.authorization = "https://accounts.google.com/o/oauth2/v2/auth";
      endpoints.token = "https://oauth2.googleapis.com/token";
      scopes = [
        "https://mail.google.com/"
        "https://www.googleapis.com/auth/calendar"
        "https://www.googleapis.com/auth/contacts"
      ];
      extras.access_type = "offline";
      auto-refresh = true;
      client-secret.command = [
        jq
        "-r"
        ".installed.client_secret"
        googleClient
      ];
      storage.read.command = [
        "${pkgs.coreutils}/bin/cat"
        "${tokenDirectory}/${account}.json"
      ];
      storage.write.command = "umask 077 && ${pkgs.coreutils}/bin/mkdir -p '${tokenDirectory}' && ${pkgs.coreutils}/bin/cat > '${tokenDirectory}/${account}.json'";
    });
  };

  # The OAuth client id lives with the client secret outside this public
  # repository, so it is merged into the generated configuration at run time.
  ortie = pkgs.writeShellApplication {
    name = "ortie";
    runtimeInputs = [ pkgs.jq ];
    text = ''
      client_id=$(jq -r .installed.client_id '${googleClient}')
      exec ${lib.getExe pimalaya.ortie} -c "${ortieConfig}:/dev/fd/3" "$@" 3< <(
        for account in ${lib.escapeShellArgs accounts}; do
          printf '[accounts.%s]\nclient-id = "%s"\n' "$account" "$client_id"
        done
      )
    '';
  };
  accessToken = account: [
    (lib.getExe ortie)
    "-a"
    account
    "token"
    "show"
  ];

  neverestConfig = toml.generate "neverest.toml" {
    accounts = forAccounts (account: {
      # A read-only mirror: Google stays authoritative and local edits are dropped.
      one-way = true;
      store.root = storeRoot account;
      gmail = {
        auth.token.command = accessToken account;
        collection.filter.exclude = [
          "SPAM"
          "TRASH"
        ];
      };
      gcal.auth.token.command = accessToken account;
      gpeople.auth.token.command = accessToken account;
    });
  };
  pimdirClientConfig = toml.generate "pimdir-client.toml" {
    accounts = forAccounts (account: {
      pimdir.root = storeRoot account;
    });
  };
  himalayaConfig = toml.generate "himalaya.toml" {
    accounts = forAccounts (account: {
      pimdir.root = storeRoot account;
      mailbox.alias = {
        inbox = "gmail/INBOX";
        sent = "gmail/SENT";
        drafts = "gmail/DRAFT";
      };
    });
  };
in
{
  home.packages = [
    # The wrapper shadows the binary; the package still contributes its completions.
    (lib.hiPrio ortie)
    pimalaya.ortie
    pimalaya.neverest
    pimalaya.calendula
    pimalaya.cardamum
    pkgs.himalaya
  ];

  xdg.configFile = {
    "neverest/config.toml".source = neverestConfig;
    "himalaya/config.toml".source = himalayaConfig;
    "calendula/config.toml".source = pimdirClientConfig;
    "cardamum/config.toml".source = pimdirClientConfig;
  };

  systemd.user = {
    services."neverest-sync@" = {
      Unit.Description = "Mirror Google account %i into its pimdir store";
      Service = {
        Type = "oneshot";
        ExecStart = "${lib.getExe pimalaya.neverest} sync --account %i";
        # 2 means the sync finished but left an item waiting for a person.
        SuccessExitStatus = 2;
        Nice = 10;
        UMask = "0077";
      };
    };
    timers = lib.genAttrs (map (account: "neverest-sync@${account}") accounts) (_: {
      Timer = {
        OnActiveSec = "1min";
        OnUnitInactiveSec = "5min";
      };
      Install.WantedBy = [ "timers.target" ];
    });
  };
}
