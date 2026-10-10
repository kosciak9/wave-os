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
    "gmail"
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
      # Google's per-user minute quotas are fixed and neverest does not back off
      # on 429, so these sources fetch one item at a time.
      gmail = {
        auth.token.command = accessToken account;
        pool-size = 1;
        collection.filter.exclude = [
          "SPAM"
          "TRASH"
        ];
      };
      gcal.auth.token.command = accessToken account;
      gpeople = {
        auth.token.command = accessToken account;
        pool-size = 1;
      };
    });
  };
  pimdirClientConfig = toml.generate "pimdir-client.toml" {
    accounts = forAccounts (account: {
      pimdir.root = storeRoot account;
    });
  };
  # calendula 0.2.0 filters by a series' first start, so the agenda expands
  # recurrences itself until a release ships its occurrence expansion.
  agenda = pkgs.writeScriptBin "wave-agenda" (
    "#!${
      lib.getExe (
        pkgs.python3.withPackages (ps: [
          ps.icalendar
          ps.recurring-ical-events
          ps.shtab
        ])
      )
    }\n"
    + builtins.readFile ./agenda.py
  );
  # Proton Mail through the local Bridge, whose own cache already mirrors the
  # mailbox, so himalaya reads it over IMAP rather than through neverest.
  protonAddress = osConfig.sops.secrets."protonmail/address".path;
  protonPassword = osConfig.sops.secrets."protonmail/bridge-password".path;
  bridgeImap = {
    host = "127.0.0.1";
    port = 1143;
  };
  cat = lib.getExe' pkgs.coreutils "cat";
  himalayaConfig = toml.generate "himalaya.toml" {
    accounts =
      forAccounts (account: {
        pimdir.root = storeRoot account;
        mailbox.alias = {
          inbox = "gmail/INBOX";
          sent = "gmail/SENT";
          drafts = "gmail/DRAFT";
        };
      })
      // {
        # Bridge accepts plain authentication on loopback without TLS.
        personal.imap = {
          server = "imap://${bridgeImap.host}:${toString bridgeImap.port}";
          sasl.plain.password.command = [
            cat
            protonPassword
          ];
        };
      };
  };
  # The Proton address stays out of this public repository, so it is merged
  # into the generated configuration at run time.
  himalaya = pkgs.writeShellApplication {
    name = "himalaya";
    text = ''
      exec ${lib.getExe pkgs.himalaya} -c "${himalayaConfig}:/dev/fd/3" "$@" 3< <(
        printf '[accounts.personal.imap.sasl.plain]\nusername = "%s"\n' "$(< '${protonAddress}')"
      )
    '';
  };
  # The mail panel rereads its inboxes over Quickshell IPC; a shell that is
  # not running has nothing to update.
  refreshMailPanel = "${lib.getExe config.programs.quickshell.package} -c wave ipc call mail refresh";
  imapNotifyConfig = (pkgs.formats.json { }).generate "goimapnotify.json" {
    configurations = [
      {
        inherit (bridgeImap) host port;
        tls = false;
        tlsOptions = {
          starttls = false;
          rejectUnauthorized = false;
        };
        usernameCMD = "${cat} ${protonAddress}";
        passwordCMD = "${cat} ${protonPassword}";
        boxes = [
          {
            mailbox = "INBOX";
            onNewMail = refreshMailPanel;
            onChangedMail = refreshMailPanel;
            onDeletedMail = refreshMailPanel;
          }
        ];
      }
    ];
  };
in
{
  home.packages = [
    # The wrappers shadow the binaries; the packages still contribute their completions.
    (lib.hiPrio ortie)
    (lib.hiPrio himalaya)
    pimalaya.ortie
    pimalaya.neverest
    pimalaya.calendula
    pimalaya.cardamum
    pkgs.himalaya
    agenda
  ];
  programs.zsh.generatedCompletions = {
    wave-agenda = "${lib.getExe agenda} --print-completion zsh";
    # Bridge prints only --help, which zsh's generic completion parses.
    protonmail-bridge = "printf '#compdef protonmail-bridge\\n_gnu_generic\\n'";
  };

  services.protonmail-bridge = {
    enable = true;
    # Bridge keeps its vault key in pass.
    extraPackages = [
      config.programs.password-store.package
      pkgs.gnupg
    ];
  };

  xdg.configFile = {
    "neverest/config.toml".source = neverestConfig;
    "calendula/config.toml".source = pimdirClientConfig;
    "cardamum/config.toml".source = pimdirClientConfig;
  };

  systemd.user = {
    services."neverest-sync@" = {
      Unit.Description = "Mirror Google account %i into its pimdir store";
      Service = {
        Type = "oneshot";
        ExecStart = "${lib.getExe pimalaya.neverest} sync --account %i";
        ExecStartPost = "-${refreshMailPanel}";
        # 2 means the sync finished but left an item waiting for a person.
        SuccessExitStatus = 2;
        Nice = 10;
        UMask = "0077";
      };
    };
    # Bridge's IMAP IDLE stands in for neverest's sync hook on the Proton inbox.
    services.goimapnotify-proton = {
      Unit = {
        Description = "Refresh the mail panel on Proton Mail inbox changes";
        After = [ "protonmail-bridge.service" ];
        BindsTo = [ "protonmail-bridge.service" ];
      };
      Service = {
        ExecStart = "${lib.getExe pkgs.goimapnotify} -conf ${imapNotifyConfig}";
        Restart = "always";
        RestartSec = 30;
      };
      Install.WantedBy = [ "protonmail-bridge.service" ];
    };
    timers = lib.genAttrs (map (account: "neverest-sync@${account}") accounts) (_: {
      Timer = {
        OnActiveSec = "1min";
        OnUnitInactiveSec = "15min";
      };
      Install.WantedBy = [ "timers.target" ];
    });
  };
}
