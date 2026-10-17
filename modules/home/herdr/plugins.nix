{
  pkgs,
  lib,
  config,
  ...
}:
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
  editorLinks = pkgs.writeScript "herdr-editor-links" ''
    #!${pkgs.python3}/bin/python3
    ${builtins.readFile ./editor-links.py}
  '';
  nvim = lib.getExe config.programs.neovim.finalPackage;
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
  editor-links = stage "herdr-editor-links-plugin" {
    id = "herdr.editor-links";
    name = "Editor Links";
    version = "1.0.0";
    min_herdr_version = "0.8.2";
    platforms = [
      "linux"
      "macos"
    ];
    actions = [
      {
        id = "open";
        title = "Open file in editor";
        contexts = [ "pane" ];
        command = [
          (toString editorLinks)
          "open"
        ]
        ++ (
          if config.programs.herdr.guiEditor then
            [
              "gui"
              "${pkgs.systemd}/bin/systemd-run"
              (lib.getExe pkgs.neovide)
              nvim
            ]
          else
            [ "split" ]
        );
      }
    ];
    link_handlers = [
      {
        id = "editor";
        title = "Open file at line";
        pattern = "^herdr-edit:///";
        action = "open";
      }
    ];
    panes = [
      {
        id = "editor";
        title = "Neovim";
        placement = "split";
        command = [
          (toString editorLinks)
          "terminal"
          nvim
        ];
      }
    ];
  };
}
