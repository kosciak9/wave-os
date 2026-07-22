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
target=$((maximum / 10))
if (( target < 1 )); then
    target=1
fi
if (( original < target )); then
    target=$original
fi

restore() {
    if [[ -e /sys/class/backlight/$device/brightness ]]; then
        brightnessctl --quiet --device "$device" set "$original" || true
    fi
}
trap restore EXIT
trap 'exit 0' HUP INT TERM

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
