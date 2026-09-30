{ inputs, pkgs, ... }:

let
  # Mirror the AUR package's core dependencies so optional database drivers stay optional.
  sqlit = inputs.sqlit.lib.${pkgs.stdenv.hostPlatform.system}.makeSqlit {
    extras = [ "postgres" ];
  };
  weave = pkgs.callPackage ../../../packages/weave.nix { };
in
{
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
