{ inputs, pkgs, ... }:

let
  devenv = inputs.devenv-nixpkgs.legacyPackages.${pkgs.stdenv.hostPlatform.system}.devenv;
in
{
  home.packages = [ devenv ];
  programs.zsh.generatedCompletions.secretspec = "${devenv}/bin/secretspec completions zsh";

  programs.direnv = {
    enable = true;
    enableZshIntegration = true;
  };
}
