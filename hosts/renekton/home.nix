{ lib, ... }:
{
  imports = [
    ../../modules/home/agents
    ../../modules/home/openclaw
    ../../modules/home/slack-mirror
    ../../modules/home/camofox
    ../../modules/home/lightpanda
    ../../modules/home/cli
    ../../modules/home/devenv
    ../../modules/home/development-caddy/darwin.nix
    ../../modules/home/ghostty
    ../../modules/home/git.nix
    ../../modules/home/neovim
    ../../modules/home/opencode
    ../../modules/home/herdr
    ../../modules/home/starship
    ../../modules/home/vicinae
    ../../modules/home/whisper/darwin.nix
    ../../modules/home/zoxide
    ../../modules/home/zen-browser
    ../../modules/home/zsh
    ../../modules/home/anytype
    ./aerospace.nix
  ];

  home = {
    username = "kosciak";
    homeDirectory = "/Users/kosciak";
    stateVersion = "26.05";
    activation.switchStatus = lib.hm.dag.entryBefore [ "writeBoundary" ] ''
      printf 'Home Manager activation started (PID %s, %s).\n' "$$" "$(/bin/date "+%Y-%m-%dT%H:%M:%S%z")" >&2
      if [[ "$(/bin/launchctl managername)" != Aqua ]]; then
        /usr/bin/osascript -e 'display notification "Home Manager activation started. Check macOS for permission prompts." with title "Nix switch"' \
          >/dev/null 2>&1 </dev/null || true
      fi
    '';
  };
  services.slack-mirror = {
    enable = true;
    sync.enable = true;
    # Podman permits one active VM; sharing it does not couple service lifecycles.
    machineName = "openclaw-sandbox";
  };
  programs = {
    home-manager.enable = true;
    herdr.federation = {
      coordinator = true;
      savedMachines."9717018a05f556969843d066b82d2988" = "machine_77c29d300c7ac622a2dfc783ac227170";
    };
    zen-browser = {
      enable = true;
      package = null;
      profileName = "wave";
      installId = "6ED35B3CA1B5D3AF";
      settings = (import ../../modules/home/zen-browser/config/settings.nix) // {
        "browser.startup.homepage" = "https://development-caddy.localhost";
        "browser.startup.page" = 1;
      };
    };
    ghostty.settings = {
      macos-titlebar-style = "hidden";
      macos-icon = "custom";
      macos-custom-icon = "~/.config/secrets/kanagawa-wave-ghostty.icns";
    };
  };
  targets.darwin = {
    linkApps.enable = true;
    copyApps.enable = false;
  };
  xdg.enable = true;
}
