{ pkgs, lib, ... }:
let
  toml = pkgs.formats.toml { };
  stage =
    name: manifest:
    pkgs.runCommand name { } ''
      mkdir -p "$out"
      cp ${toml.generate "herdr-plugin.toml" manifest} "$out/herdr-plugin.toml"
    '';
  openPane = plugin: entrypoint: [
    "${pkgs.bash}/bin/bash"
    "-c"
    ''exec "$HERDR_BIN_PATH" plugin pane open --plugin ${plugin} --entrypoint ${entrypoint} --focus''
  ];
  autoTitle = pkgs.writeShellScript "herdr-auto-title" ''
    export HERDR_AUTO_TITLE_PANES=true
    export HERDR_AUTO_TITLE_WORKSPACES=false
    exec ${lib.getExe pkgs.herdr-auto-title} "$@"
  '';
  usageDashboard = pkgs.writeShellScript "herdr-usage-dashboard" ''
    export HERDR_AGENT_USAGE_DASHBOARD_ONLY=1
    ${lib.getExe pkgs.herdr-agent-usage} refresh --provider all || true
    exec ${lib.getExe pkgs.herdr-agent-usage} dashboard
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
  usage = stage "herdr-agent-usage-plugin" {
    id = "herdr-agent-usage";
    name = "Agent Usage";
    version = pkgs.herdr-agent-usage.version;
    min_herdr_version = "0.9.0";
    platforms = [
      "linux"
      "macos"
    ];
    actions = [
      {
        id = "open";
        title = "Open agent limits";
        command = openPane "herdr-agent-usage" "dashboard";
      }
    ];
    panes = [
      {
        id = "dashboard";
        title = "Agent limits";
        placement = "popup";
        width = "80%";
        height = "80%";
        command = [ (toString usageDashboard) ];
      }
    ];
  };
}
