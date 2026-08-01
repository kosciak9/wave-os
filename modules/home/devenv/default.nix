{ inputs, pkgs, ... }:

{
  home.packages = [ inputs.devenv-nixpkgs.legacyPackages.${pkgs.stdenv.hostPlatform.system}.devenv ];

  programs.direnv = {
    enable = true;
    enableZshIntegration = true;
  };
}
