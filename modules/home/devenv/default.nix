{ lib, pkgs, ... }:

{
  home.packages = [ pkgs.devenv ];

  programs.zsh = {
    enable = true;
    initContent = lib.mkOrder 2000 ''
      eval "$(${lib.getExe pkgs.devenv} hook zsh)"
    '';
  };
}
