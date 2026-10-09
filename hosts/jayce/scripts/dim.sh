#!/usr/bin/env bash

set -euo pipefail

if ! hyprctl monitors -j | jq -e 'any(.[]; .name == "eDP-1" and (.disabled | not))' >/dev/null; then
    exit 0
fi

device=""
current=""
maximum=""
while IFS=, read -r candidate class value _ max; do
    if [[ $class == backlight ]]; then
        device=$candidate
        current=$value
        maximum=$max
        break
    fi
done < <(brightnessctl --class backlight --machine-readable)

if [[ -z $device || ! $current =~ ^[0-9]+$ || ! $maximum =~ ^[0-9]+$ ]]; then
    exit 0
fi

original=$current
# The Framework 16 keyboard module drives its own backlight through QMK; the
# EC's kbd_backlight LED does not reach it.
keyboard_original=""
if output=$(qmk_hid via --backlight 2>/dev/null) && [[ $output =~ Brightness:\ ([0-9]+)% ]]; then
    keyboard_original=${BASH_REMATCH[1]}
fi
target=$((maximum / 10))
if (( target < 1 )); then
    target=1
fi
if (( original < target )); then
    target=$original
fi

restore() {
    if [[ -n $keyboard_original ]]; then
        qmk_hid via --backlight "$keyboard_original" >/dev/null 2>&1 || true
    fi
    if [[ -e /sys/class/backlight/$device/brightness ]]; then
        brightnessctl --quiet --device "$device" set "$original" || true
    fi
}
trap restore EXIT
trap 'exit 0' HUP INT TERM

if [[ -n $keyboard_original ]]; then
    qmk_hid via --backlight 0 >/dev/null 2>&1 || true
fi

steps=40
for ((step = 1; step <= steps; step++)); do
    value=$((original + (target - original) * step / steps))
    brightnessctl --quiet --device "$device" set "$value"
    sleep 0.05
done

while true; do
    sleep 3600 &
    wait $!
done
