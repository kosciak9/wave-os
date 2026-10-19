{
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [
    ../../modules/wave/darwin.nix
    ../../modules/sops.nix
    ../../modules/caddy/darwin.nix
    ../../modules/cliproxyapi/darwin.nix
    ./firewall.nix
    ./network-guard.nix
    ./power.nix
    ./spotlight.nix
  ];

  system = {
    primaryUser = "kosciak";
    stateVersion = 1;

    defaults = {
      dock = {
        show-process-indicators = true;
        show-recents = true;
        wvous-tl-corner = 2; # Mission Control
        wvous-tr-corner = 1; # Disabled
        wvous-bl-corner = 1; # Disabled
        wvous-br-corner = 1; # Disabled
      };

      NSGlobalDomain = {
        AppleInterfaceStyle = "Dark";
      };

      CustomUserPreferences = {
        NSGlobalDomain = {
          AppleAccentColor = 1; # Orange
          AppleAquaColorVariant = 1;
        };

        "com.apple.dock" = {
          show-recents-count = 1;
        };

      };
    };
  };

  networking = {
    hostName = "renekton";
    localHostName = "renekton";
    computerName = "renekton";
  };

  wave.health.checks.t3code = ''
    ${lib.getExe pkgs.curl} -q -fsS --max-time 3 \
      https://renekton.dusky-diatonic.ts.net:18443/.well-known/t3/environment \
      >/dev/null
  '';

  system.activationScripts.userDefaults.text = lib.mkMerge [
    (lib.mkBefore ''
      wave_dock_preferences() {
        /bin/launchctl asuser "$(/usr/bin/id -u ${lib.escapeShellArg config.system.primaryUser})" \
          /usr/bin/sudo --user ${lib.escapeShellArg config.system.primaryUser} -- \
          /usr/bin/defaults export com.apple.dock - 2>/dev/null
      }
      wave_dock_preferences_before=$(wave_dock_preferences) || wave_dock_preferences_before=""

      # nix-darwin restarts Dock after writing defaults, including unchanged values.
      # Keep its typed options and activation, but restart only if the domain changed.
      killall() {
        if [ "$#" = 3 ] && [ "$1" = -qu ] \
          && [ "$2" = ${lib.escapeShellArg config.system.primaryUser} ] && [ "$3" = Dock ] \
          && [ -n "$wave_dock_preferences_before" ]; then
          local wave_dock_preferences_after
          if wave_dock_preferences_after=$(wave_dock_preferences) \
            && [ "$wave_dock_preferences_before" = "$wave_dock_preferences_after" ]; then
            return 0
          fi
        fi
        command killall "$@"
      }
    '')
    (lib.mkAfter ''
      unset -f killall wave_dock_preferences
      unset wave_dock_preferences_before
    '')
  ];

  # Replaces nix-darwin's networking step, which re-sets the names on every activation;
  # renekton's network dropped during that step, so names are written only on drift.
  # Preserve application firewall options while avoiding an unchanged global-state write.
  system.activationScripts.networking.text = lib.mkForce (
    let
      inherit (config.networking) applicationFirewall;
      onOff = enabled: if enabled then "on" else "off";
    in
    ''
      echo "configuring networking..." >&2

      ensure_scutil_name() {
        local key="$1" value="$2"
        if [ "$(/usr/sbin/scutil --get "$key" 2>/dev/null)" != "$value" ]; then
          /usr/sbin/scutil --set "$key" "$value"
        fi
      }

      ensure_scutil_name ComputerName ${lib.escapeShellArg config.networking.computerName}
      ensure_scutil_name HostName ${lib.escapeShellArg config.networking.hostName}
      ensure_scutil_name LocalHostName ${lib.escapeShellArg config.networking.localHostName}

      echo "configuring application firewall..." >&2

      ${lib.optionalString (applicationFirewall.enable != null) ''
        if ! /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate \
          | /usr/bin/grep -F '(State = ${if applicationFirewall.enable then "1" else "0"})' >/dev/null; then
          /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate ${onOff applicationFirewall.enable}
        fi
      ''}
      ${lib.optionalString (applicationFirewall.blockAllIncoming != null) ''
        /usr/libexec/ApplicationFirewall/socketfilterfw --setblockall ${onOff applicationFirewall.blockAllIncoming}
      ''}
    ''
  );

  users.users.kosciak = {
    name = "kosciak";
    home = "/Users/kosciak";
  };

  # The Home Manager services read these through osConfig.
  sops.secrets =
    lib.genAttrs
      [
        "alfred/env"
        "frida/env"
        "frida/mcp-token"
        "frida/home-assistant-mcp-url"
        "frida/anytype-api-key"
        "frida/anytype-space-id"
        "alfred/prompt.md"
        "alfred/mcp-token"
        "alfred/obsidian-vault-path"
        "alfred/google-workspace-client.json"
        "alfred/google-workspace-email"
        "alfred/twenty-mcp-url"
        "alfred/twenty-api-key"
        "alfred/substack-publication-url"
        "alfred/substack-session-token"
        "alfred/x-session.json"
        "camofox/access-key"
        "protonmail/address"
        "protonmail/bridge-password"
        "cliproxyapi/api-key"
        "cliproxyapi/base-url"
        "cliproxyapi/quota-key"
        "cliproxyapi/client-keys"
        "cliproxyapi/management-key"
        "cliproxyapi/opencode-go-keys"
        "cliproxyapi/opencode-zen-keys"
        "slack-mirror/mcp-token"
        "slack-mirror/session.json"
      ]
      (_: {
        owner = "kosciak";
      });

  nixpkgs.config.allowUnfree = true;
  environment.systemPackages = with pkgs; [
    fd
    mosh
    neovide
    neovim
    nodejs
    obsidian
    gnupg
    pass
    pinentry_mac
    podman
    ripgrep
    syncthing-macos
    tailscale
    tree-sitter
    zsh
  ];

  fonts.packages = [
    pkgs.overpass
    pkgs.nerd-fonts.overpass
    pkgs.noto-fonts
    pkgs.noto-fonts-color-emoji
  ];

  services.tailscale.enable = true;
  services.openssh.enable = true;

  wave.deployTarget.enable = true;
  # Tailscale 1.98+ manages /etc/resolver/ts.net itself and rejects nix-darwin's
  # symlink because it escapes os.Root("/etc/resolver").
  environment.etc."resolver/ts.net".enable = lib.mkForce false;

  determinateNix.enable = true;
}
