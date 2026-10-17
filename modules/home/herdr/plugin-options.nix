{ lib, pkgs, ... }:
{
  options.programs.herdr.guiEditor = lib.mkOption {
    type = lib.types.bool;
    default = pkgs.stdenv.hostPlatform.isLinux;
    description = "Open editor links in Neovide instead of a terminal split.";
  };
  options.programs.herdr.extraPlugins = lib.mkOption {
    type = lib.types.attrsOf lib.types.path;
    default = { };
    description = "Additional declaratively registered Herdr plugin directories.";
  };
}
