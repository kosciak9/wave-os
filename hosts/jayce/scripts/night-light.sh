#!/usr/bin/env bash

set -euo pipefail

cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/wave"
cache_file="$cache_dir/location"
mkdir -p "$cache_dir"

latitude=52.2
longitude=21.0
last_location_update=0
next_location_retry=0
last_setting=""

valid_coordinate() {
    [[ $1 =~ ^-?[0-9]+([.][0-9]+)?$ ]] &&
        awk -v value="$1" -v minimum="$2" -v maximum="$3" \
            'BEGIN { exit !(value >= minimum && value <= maximum) }'
}

load_cached_location() {
    local cached_latitude cached_longitude
    if [[ -r $cache_file ]]; then
        read -r cached_latitude cached_longitude < "$cache_file" || true
        if valid_coordinate "$cached_latitude" -90 90 &&
            valid_coordinate "$cached_longitude" -180 180; then
            latitude=$cached_latitude
            longitude=$cached_longitude
        fi
    fi
}

refresh_location() {
    local output candidate_latitude candidate_longitude now
    now=$(date +%s)
    if ((now < next_location_retry || now - last_location_update < 21600)); then
        return
    fi

    output=$(timeout 25 @where-am-i@ -t 20 -a 4 2>/dev/null || true)
    candidate_latitude=$(awk -F: '/Latitude/ { if (match($2, /-?[0-9]+([.][0-9]+)?/)) print substr($2, RSTART, RLENGTH); exit }' <<< "$output")
    candidate_longitude=$(awk -F: '/Longitude/ { if (match($2, /-?[0-9]+([.][0-9]+)?/)) print substr($2, RSTART, RLENGTH); exit }' <<< "$output")

    if valid_coordinate "$candidate_latitude" -90 90 &&
        valid_coordinate "$candidate_longitude" -180 180; then
        latitude=$candidate_latitude
        longitude=$candidate_longitude
        printf '%s %s\n' "$latitude" "$longitude" > "$cache_file"
        last_location_update=$now
        next_location_retry=0
    else
        # Keep Warsaw (or a valid cache), but retry GeoClue soon rather than
        # treating a failed request as a successful six-hour refresh.
        next_location_retry=$((now + 300))
    fi
}

load_cached_location

sunwait_coordinate() {
    local value=$1 positive=$2 negative=$3
    awk -v value="$value" -v positive="$positive" -v negative="$negative" 'BEGIN {
        if (value < 0) printf "%.6f%s", -value, negative;
        else printf "%.6f%s", value, positive;
    }'
}

apply_setting() {
    local setting=$1
    if [[ $setting == "$last_setting" ]]; then
        return
    fi

    if [[ $setting == identity ]]; then
        hyprctl hyprsunset identity >/dev/null 2>&1 || return
    else
        hyprctl hyprsunset temperature "$setting" >/dev/null 2>&1 || return
    fi
    last_setting=$setting
}

while true; do
    refresh_location

    lat=$(sunwait_coordinate "$latitude" N S)
    lon=$(sunwait_coordinate "$longitude" E W)
    civil=$(sunwait list civil "$lat" "$lon" 2>/dev/null || true)
    daylight=$(sunwait list daylight "$lat" "$lon" 2>/dev/null || true)

    timings_valid=false
    if [[ $civil =~ ^([0-9]{2}:[0-9]{2}),[[:space:]]*([0-9]{2}:[0-9]{2})$ ]]; then
        civil_rise=${BASH_REMATCH[1]}
        civil_set=${BASH_REMATCH[2]}
        if [[ $daylight =~ ^([0-9]{2}:[0-9]{2}),[[:space:]]*([0-9]{2}:[0-9]{2})$ ]]; then
            sunrise=${BASH_REMATCH[1]}
            sunset=${BASH_REMATCH[2]}
            timings_valid=true
        fi
    fi

    if [[ $timings_valid == true ]]; then
        now=$(date +%s)
        civil_rise_epoch=$(date --date="today $civil_rise" +%s)
        sunrise_epoch=$(date --date="today $sunrise" +%s)
        sunset_epoch=$(date --date="today $sunset" +%s)
        civil_set_epoch=$(date --date="today $civil_set" +%s)

        if ((now < civil_rise_epoch || now >= civil_set_epoch)); then
            apply_setting 4000
        elif ((now < sunrise_epoch)); then
            temperature=$((4000 + 2500 * (now - civil_rise_epoch) / (sunrise_epoch - civil_rise_epoch)))
            apply_setting "$temperature"
        elif ((now < sunset_epoch)); then
            apply_setting identity
        else
            temperature=$((6500 - 2500 * (now - sunset_epoch) / (civil_set_epoch - sunset_epoch)))
            apply_setting "$temperature"
        fi
    else
        apply_setting 4000
    fi

    sleep 60
done
