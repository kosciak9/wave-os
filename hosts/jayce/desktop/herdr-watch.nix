{ pkgs, itctl }:
let
  notify = pkgs.writeShellApplication {
    name = "herdr-watch-notify";
    runtimeInputs = [ pkgs.jq ];
    text = ''
      event="$HERDR_PLUGIN_EVENT_JSON"
      jq -e '.data.agent_status == "done"' \
        <<< "$event" >/dev/null || exit 0
      body=$(jq -r --argjson context "$HERDR_PLUGIN_CONTEXT_JSON" '
        .data | [(.display_agent // .agent // "Agent"),
          ($context.workspace_label // .workspace_id),
          (.title // $context.tab_label // .pane_id)] | join(" / ")
        ' <<< "$event")
      exec ${itctl}/bin/itctl notify "Herdr: agent finished" "$body"
    '';
  };
  manifest = (pkgs.formats.toml { }).generate "herdr-plugin.toml" {
    id = "wave.watch-notify";
    name = "InfiniTime agent notifications";
    version = "0.1.0";
    min_herdr_version = "0.9.3";
    platforms = [ "linux" ];
    events = [
      {
        on = "pane.agent_status_changed";
        command = [ "${notify}/bin/herdr-watch-notify" ];
      }
    ];
  };
in
pkgs.runCommand "herdr-watch-notify-plugin" { } ''
  mkdir -p "$out"
  cp ${manifest} "$out/herdr-plugin.toml"
''
