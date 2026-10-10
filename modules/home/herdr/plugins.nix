{ pkgs, lib, ... }:
let
  toml = pkgs.formats.toml { };
  stage =
    name: manifest:
    pkgs.runCommand name { } ''
      mkdir -p "$out"
      cp ${toml.generate "herdr-plugin.toml" manifest} "$out/herdr-plugin.toml"
    '';
  autoTitle = pkgs.writeShellScript "herdr-auto-title" ''
    export HERDR_AUTO_TITLE_PANES=true
    export HERDR_AUTO_TITLE_WORKSPACES=false
    exec ${lib.getExe pkgs.herdr-auto-title} "$@"
  '';
in
{
  auto-title = stage "herdr-auto-title-plugin" {
    id = "herdr.auto-title";
    name = "Auto Title";
    version = pkgs.herdr-auto-title.version;
    min_herdr_version = "0.8.2";
    platforms = [
      "linux"
      "macos"
    ];
    startup = [ { command = [ (toString autoTitle) ]; } ];
    actions = [
      {
        id = "restart";
        title = "Auto Title: restart";
        contexts = [ "global" ];
        command = [
          (toString autoTitle)
          "restart"
        ];
      }
    ];
  };
}
