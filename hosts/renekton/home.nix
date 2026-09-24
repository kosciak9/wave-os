{ lib, ... }:
{
  imports = [
    ../../modules/home/openclaw
    ../../modules/home/camofox
    ../../modules/home/cli
    ../../modules/home/devenv
    ../../modules/home/development-caddy/darwin.nix
    ../../modules/home/ghostty
    ../../modules/home/git.nix
    ../../modules/home/neovim
    ../../modules/home/opencode
    ../../modules/home/opencode/darwin.nix
    ../../modules/home/starship
    ../../modules/home/vicinae
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
  programs = {
    home-manager.enable = true;
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
