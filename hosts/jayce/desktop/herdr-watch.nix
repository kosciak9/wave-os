{ pkgs, itctl }:
let
  notify = pkgs.writeShellApplication {
    name = "herdr-watch-notify";
    runtimeInputs = [
      pkgs.jq
      pkgs.coreutils
      pkgs.util-linux
    ];
    text = ''
      event="$HERDR_PLUGIN_EVENT_JSON"
      jq -e '.data | .agent_status == "done" and (.turn // 0) > 0 and (.input_pending != true)' \
        <<< "$event" >/dev/null || exit 0
      key=$(printf '%s\n%s' "$HERDR_SOCKET_PATH" "$(jq -r '.data | [.pane_id, .turn_epoch] | @json' <<< "$event")" | sha256sum | cut -d' ' -f1)
      exec 9>"$HERDR_PLUGIN_STATE_DIR/$key.lock"
      flock -w 1 9 || exit 0
      turn=$(jq -r '.data.turn' <<< "$event")
      previous=$(cat "$HERDR_PLUGIN_STATE_DIR/$key.turn" 2>/dev/null || echo 0)
      (( turn > previous )) || exit 0
      printf '%s' "$turn" >"$HERDR_PLUGIN_STATE_DIR/$key.turn"
      [[ -S "''${XDG_RUNTIME_DIR:-}/itd/socket" ]] || exit 0
      body=$(jq -r --argjson context "$HERDR_PLUGIN_CONTEXT_JSON" '
        .data | [(.display_agent // .agent // "Agent"),
          ($context.workspace_label // .workspace_id),
          (.title // $context.tab_label // .pane_id)] | join(" / ")
        ' <<< "$event")
      timeout 5 ${itctl}/bin/itctl notify "Herdr: agent finished" "$body" || true
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
