{ lib, ... }:
{
  options.programs.herdr.extraPlugins = lib.mkOption {
    type = lib.types.attrsOf lib.types.path;
    default = { };
    description = "Additional declaratively registered Herdr plugin directories.";
  };
}
