{
  inputs,
  lib,
  pkgs,
  ...
}:

let
  # Mirror the AUR package's core dependencies so optional database drivers stay optional.
  sqlit = inputs.sqlit.lib.${pkgs.stdenv.hostPlatform.system}.makeSqlit {
    extras = [ "postgres" ];
  };
  weave = pkgs.callPackage ../../../packages/weave.nix { };
in
{
  # System GC skips Home Manager generations in ~/.local/state/nix/profiles.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
    persistent = true;
  };
  # Home Manager passes the options string as one launchd argument on darwin.
  launchd.agents.nix-gc.config.ProgramArguments = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin (
    lib.mkForce [
      "/nix/var/nix/profiles/default/bin/nix-collect-garbage"
      "--delete-older-than"
      "14d"
    ]
  );

  home.packages = with pkgs; [
    bat
    btop
    gh
    httpie
    infisical
    plannotator
    sqlit
    tmux
    weave
  ];
}
