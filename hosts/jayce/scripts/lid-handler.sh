#!/usr/bin/env bash

set -euo pipefail

state_file="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/wave-lid-workspaces.json"
last_external=""
suspended=false

read_lid() {
    local file state
    for file in /proc/acpi/button/lid/*/state; do
        [[ -r $file ]] || continue
        read -r _ state < "$file"
        printf '%s\n' "${state,,}"
        return
    done
    printf '%s\n' unknown
}

monitors() { hyprctl monitors -j 2>/dev/null || printf '[]\n'; }

monitor_exists() {
    jq -e --arg monitor "$1" 'any(.[]; .name == $monitor)' <<< "$(monitors)" \
        >/dev/null
}

trigger_blackout() {
    qs -c wave ipc call blackout trigger >/dev/null 2>&1 || true
    # Let the compositor render the blackout before changing display state.
    sleep 0.08
}

lua_string() { jq -Rn --arg value "$1" '$value'; }

workspace_on_monitor() {
    local workspace=$1 monitor=$2
    hyprctl workspaces -j | jq -e --argjson workspace "$workspace" \
        --arg monitor "$monitor" \
        'any(.[]; .id == $workspace and .monitor == $monitor)' >/dev/null
}

move_workspace() {
    local workspace=$1 monitor=$2 workspace_lua monitor_lua
    workspace_lua=$(lua_string "$workspace")
    monitor_lua=$(lua_string "$monitor")
    for _ in {1..12}; do
        if workspace_on_monitor "$workspace" "$monitor"; then
            return 0
        fi
        hyprctl dispatch "hl.dsp.workspace.move({ workspace = $workspace_lua, monitor = $monitor_lua })" \
            >/dev/null 2>&1 || true
        sleep 0.1
    done
    workspace_on_monitor "$workspace" "$monitor"
}

write_state() {
    local content=$1 temporary
    temporary="${state_file}.tmp.$$"
    printf '%s\n' "$content" > "$temporary"
    mv -f -- "$temporary" "$state_file"
}

target_external() {
    local snapshot=$1 candidate
    [[ -n $last_external ]] &&
        jq -e --arg monitor "$last_external" 'any(.[]; .name == $monitor)' <<< "$snapshot" >/dev/null && {
            printf '%s\n' "$last_external"
            return
        }
    candidate=$(jq -r 'first(.[] | select(.name != "eDP-1") | .name) // empty' <<< "$snapshot")
    printf '%s\n' "$candidate"
}

suspend_for_lid() {
    trigger_blackout
    systemctl --user stop wave-backlight-dim.service >/dev/null 2>&1 || true
    loginctl lock-session
    systemctl suspend
    suspended=true
}

begin_close() {
    local snapshot target workspaces
    snapshot=$(monitors)
    target=$(target_external "$snapshot")
    if [[ -z $target ]]; then
        suspend_for_lid
        return
    fi

    trigger_blackout
    systemctl --user stop wave-backlight-dim.service >/dev/null 2>&1 || true
    workspaces=$(hyprctl workspaces -j | jq '[.[] |
        select(.monitor == "eDP-1" and .id > 0) | {id: .id}]')
    # The migration is recoverable because this transaction is persisted
    # before its first workspace or monitor operation.
    write_state "$(jq -cn --arg phase migrating --arg target "$target" \
        --argjson workspaces "$workspaces" \
        '{phase: $phase, targetMonitor: $target, workspaces: $workspaces}')"
}

reconcile_closed() {
    local snapshot target workspace failed=false
    [[ -s $state_file ]] || begin_close
    [[ -s $state_file ]] || return

    snapshot=$(monitors)
    if ! jq -e 'any(.[]; .name != "eDP-1")' <<< "$snapshot" >/dev/null; then
        suspend_for_lid
        return
    fi
    target=$(jq -r '.targetMonitor // empty' "$state_file")
    if ! monitor_exists "$target"; then
        target=$(target_external "$snapshot")
        write_state "$(jq --arg target "$target" '.targetMonitor = $target' "$state_file")"
    fi

    # Verify even a state already marked closed: a process restart may have
    # happened after only part of the migration completed.
    while IFS= read -r workspace; do
        [[ -n $workspace ]] || continue
        move_workspace "$workspace" "$target" || failed=true
    done < <(jq -r '.workspaces[]?.id | tostring' "$state_file")
    hyprctl eval 'hl.monitor({ output = "eDP-1", disabled = true })' >/dev/null 2>&1 || failed=true
    monitor_exists eDP-1 && failed=true
    if [[ $failed == false ]]; then
        write_state "$(jq '.phase = "closed"' "$state_file")"
    fi
}

restore_internal() {
    local workspace failed=false
    [[ -s $state_file ]] || return
    trigger_blackout
    write_state "$(jq '.phase = "opening"' "$state_file")"
    hyprctl eval 'hl.monitor({ output = "eDP-1", mode = "2560x1600@165.000", position = "auto", scale = 1.6, vrr = 1 })' \
        >/dev/null 2>&1 || true
    for _ in {1..40}; do
        monitor_exists eDP-1 && break
        sleep 0.1
    done
    monitor_exists eDP-1 || return 1
    while IFS= read -r workspace; do
        [[ -n $workspace ]] || continue
        move_workspace "$workspace" eDP-1 || failed=true
    done < <(jq -r '.workspaces[]?.id | tostring' "$state_file")
    [[ $failed == false ]] || return 1
    rm -f -- "$state_file"
}

while true; do
    snapshot=$(monitors)
    focused_external=$(jq -r 'first(.[] | select(.name != "eDP-1" and .focused) | .name) // empty' <<< "$snapshot")
    [[ -n $focused_external ]] && last_external=$focused_external

    lid=$(read_lid)
    if [[ $lid == closed ]]; then
        if [[ $suspended == false ]]; then
            [[ -s $state_file ]] || begin_close
            [[ $suspended == false ]] && reconcile_closed
        fi
    elif [[ $lid == open ]]; then
        if [[ -s $state_file ]]; then
            restore_internal || true
        fi
        suspended=false
    fi
    sleep 0.2
done
