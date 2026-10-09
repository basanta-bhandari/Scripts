#!/usr/bin/env bash
#
# toggle-internal-kb.sh — Switch the laptop between normal, temporary
# Tailscale SSH, and external-peripheral desktop modes.
#
# Usage:
#   ./toggle-internal-kb.sh ssh    # temporary remote/headless mode
#   ./toggle-internal-kb.sh prph   # external-peripheral desktop mode
#   ./toggle-internal-kb.sh normal # restore normal laptop operation
#   ./toggle-internal-kb.sh status # show the current state

set -euo pipefail

INPUT_ROOT="${INPUT_ROOT:-/sys/class/input}"
LEDS_ROOT="${LEDS_ROOT:-/sys/class/leds}"
POWER_SUPPLY_ROOT="${POWER_SUPPLY_ROOT:-/sys/class/power_supply}"
STATE_ROOT="${STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/toggle-internal-kb}"
MODE_FILE="${MODE_FILE:-${XDG_RUNTIME_DIR:-/run/user/$UID}/toggle-internal-kb-mode}"
CAFFEINE_UNIT="toggle-internal-kb-caffeine.service"
PRPH_KEYBOARD_UNIT="toggle-internal-kb-prph-keyboard.service"

usage() {
    echo "Usage: $0 {ssh|prph|normal|status}" >&2
    echo "       $0 mode {ssh|prph}" >&2
}

run_as_root() {
    if (( EUID == 0 )); then
        "$@"
    else
        sudo "$@"
    fi
}

write_sysfs() {
    local value=$1
    local path=$2

    if [[ -w "$path" ]]; then
        printf '%s\n' "$value" > "$path"
    else
        printf '%s\n' "$value" | sudo tee "$path" > /dev/null
    fi
}

read_device_name() {
    cat "$1/name" 2>/dev/null || true
}

ac_is_online() {
    local supply type

    for supply in "$POWER_SUPPLY_ROOT"/*; do
        [[ -r "$supply/type" && -r "$supply/online" ]] || continue
        type=$(cat "$supply/type")
        case "$type" in
            Mains|USB|USB_C|USB_PD)
                [[ "$(cat "$supply/online")" == "1" ]] && return 0
                ;;
        esac
    done

    return 1
}

battery_summary() {
    local capacity status supply

    for supply in "$POWER_SUPPLY_ROOT"/*; do
        [[ -r "$supply/type" ]] || continue
        [[ "$(cat "$supply/type")" == "Battery" ]] || continue
        capacity=$(cat "$supply/capacity" 2>/dev/null || echo unknown)
        status=$(cat "$supply/status" 2>/dev/null || echo unknown)
        printf '%s%%, %s\n' "$capacity" "$status"
        return 0
    done

    return 1
}

show_power_source() {
    local battery

    if ac_is_online; then
        echo "Power source: AC ADAPTER (battery available as automatic fallback)"
    elif battery=$(battery_summary); then
        echo "Power source: BATTERY FALLBACK ($battery)"
    else
        echo "Power source: UNKNOWN (no AC adapter or battery was detected)"
    fi
}

find_internal_keyboard() {
    local event_device

    for event_device in "$INPUT_ROOT"/event*/device; do
        [[ -e "$event_device/name" ]] || continue
        if [[ "$(read_device_name "$event_device")" == "AT Translated Set 2 keyboard" ]]; then
            printf '%s\n' "$event_device"
            return 0
        fi
    done

    return 1
}

keyboard_event_path() {
    local event_name

    event_name=${KEYBOARD_DEVICE%/device}
    event_name=${event_name##*/}
    printf '/dev/input/%s\n' "$event_name"
}

is_prph_keyboard_filter_active() {
    systemctl is-active --quiet "$PRPH_KEYBOARD_UNIT" 2>/dev/null
}

require_prph_keyboard_filter() {
    local event_path

    if ! command -v evsieve > /dev/null; then
        echo "Error: prph mode requires evsieve so Escape can remain usable." >&2
        echo "Install it first with: paru -S evsieve" >&2
        return 1
    fi

    event_path=$(keyboard_event_path)
    if [[ ! -e "$event_path" ]]; then
        echo "Error: internal keyboard event device $event_path is unavailable." >&2
        return 1
    fi
}

start_prph_keyboard_filter() {
    local event_path evsieve_path

    is_prph_keyboard_filter_active && return 0
    require_prph_keyboard_filter

    event_path=$(keyboard_event_path)
    evsieve_path=$(command -v evsieve)
    if [[ ! -e /dev/uinput ]] && command -v modprobe > /dev/null; then
        run_as_root modprobe uinput
    fi

    run_as_root systemd-run \
        --unit="$PRPH_KEYBOARD_UNIT" \
        --collect \
        --service-type=notify \
        --description="Allow only Escape from the internal keyboard" \
        --quiet \
        -- \
        "$evsieve_path" \
        --input "$event_path" grab persist=reopen \
        --output key:esc
}

stop_prph_keyboard_filter() {
    is_prph_keyboard_filter_active || return 0
    run_as_root systemctl stop "$PRPH_KEYBOARD_UNIT"
}

find_internal_pointer_devices() {
    local candidate event_device name phys resolved
    local -a touchpad_phys=()

    # First find a built-in touchpad. Built-in devices normally live on I2C,
    # serio (PS/2), or a platform bus; USB/Bluetooth pointers are excluded.
    for event_device in "$INPUT_ROOT"/event*/device; do
        [[ -e "$event_device/name" ]] || continue
        name=$(read_device_name "$event_device")
        resolved=$(readlink -f "$event_device" 2>/dev/null || true)
        if [[ "$name" =~ [Tt]ouch[Pp]ad|[Tt]rack[Pp]ad|[Cc]lick[Pp]ad ]] &&
            [[ "$resolved" =~ /(i2c|serio|platform) ]]; then
            phys=$(cat "$event_device/phys" 2>/dev/null || true)
            [[ -n "$phys" ]] && touchpad_phys+=("$phys")
            printf '%s\n' "$event_device"
        fi
    done

    # Some touchpads expose a second "Mouse" event node. Include siblings
    # with the same physical-device identifier so neither half remains live.
    for event_device in "$INPUT_ROOT"/event*/device; do
        [[ -e "$event_device/name" ]] || continue
        name=$(read_device_name "$event_device")
        [[ "$name" =~ [Tt]ouch[Pp]ad|[Tt]rack[Pp]ad|[Cc]lick[Pp]ad ]] && continue
        phys=$(cat "$event_device/phys" 2>/dev/null || true)
        for candidate in "${touchpad_phys[@]}"; do
            if [[ -n "$phys" && "$phys" == "$candidate" ]]; then
                printf '%s\n' "$event_device"
                break
            fi
        done
    done
}

is_inhibited() {
    [[ "$(cat "$1/inhibited" 2>/dev/null || true)" == "1" ]]
}

set_input_state() {
    local device=$1
    local inhibited=$2
    local label=$3

    if [[ ! -e "$device/inhibited" ]]; then
        echo "Warning: $label does not support inhibition; skipped." >&2
        return 0
    fi

    if [[ "$(cat "$device/inhibited" 2>/dev/null || true)" == "$inhibited" ]]; then
        return 0
    fi

    write_sysfs "$inhibited" "$device/inhibited"
}

keyboard_backlight_path() {
    local path

    for path in "$LEDS_ROOT"/*::kbd_backlight; do
        [[ -e "$path/brightness" ]] || continue
        printf '%s\n' "$path"
        return 0
    done

    return 1
}

save_state_once() {
    local key=$1
    local value=$2

    mkdir -p "$STATE_ROOT"
    if [[ ! -e "$STATE_ROOT/$key" ]]; then
        printf '%s\n' "$value" > "$STATE_ROOT/$key"
    fi
}

disable_keyboard_backlight() {
    local path current

    if ! path=$(keyboard_backlight_path); then
        echo "Warning: keyboard backlight was not found; skipped." >&2
        return 0
    fi

    current=$(cat "$path/brightness")
    save_state_once keyboard_backlight "$current"
    write_sysfs 0 "$path/brightness"
}

restore_keyboard_backlight() {
    local path saved

    [[ -e "$STATE_ROOT/keyboard_backlight" ]] || return 0
    if ! path=$(keyboard_backlight_path); then
        echo "Warning: keyboard backlight was not found; skipped." >&2
        return 0
    fi

    saved=$(cat "$STATE_ROOT/keyboard_backlight")
    [[ "$saved" =~ ^[0-9]+$ ]] || return 0
    write_sysfs "$saved" "$path/brightness"
    rm -f "$STATE_ROOT/keyboard_backlight"
}

disable_display() {
    local current

    if ! command -v brightnessctl > /dev/null; then
        echo "Warning: brightnessctl is unavailable; display was not dimmed." >&2
        return 0
    fi

    current=$(brightnessctl --class=backlight get 2>/dev/null || true)
    [[ "$current" =~ ^[0-9]+$ ]] && save_state_once display_brightness "$current"
    if ! brightnessctl --class=backlight set 0 > /dev/null 2>&1; then
        run_as_root brightnessctl --class=backlight set 0 > /dev/null
    fi
}

restore_display() {
    local saved

    [[ -e "$STATE_ROOT/display_brightness" ]] || return 0
    command -v brightnessctl > /dev/null || return 0
    saved=$(cat "$STATE_ROOT/display_brightness")
    [[ "$saved" =~ ^[0-9]+$ ]] || return 0
    if ! brightnessctl --class=backlight set "$saved" > /dev/null 2>&1; then
        run_as_root brightnessctl --class=backlight set "$saved" > /dev/null
    fi
    rm -f "$STATE_ROOT/display_brightness"
}

is_caffeinated() {
    systemctl is-active --quiet "$CAFFEINE_UNIT" 2>/dev/null
}

enable_caffeine() {
    is_caffeinated && return 0

    if ! command -v systemd-run > /dev/null || ! command -v systemd-inhibit > /dev/null; then
        echo "Error: systemd-run and systemd-inhibit are required for caffeinated mode." >&2
        return 1
    fi

    run_as_root systemd-run \
        --unit="$CAFFEINE_UNIT" \
        --collect \
        --property=Type=exec \
        --description="Keep the laptop awake in headless mode" \
        --quiet \
        -- \
        systemd-inhibit \
        --what=idle:sleep:handle-lid-switch \
        --who=toggle-internal-kb \
        --why="Headless SSH mode is active" \
        --mode=block \
        sleep infinity
}

disable_caffeine() {
    is_caffeinated || return 0
    run_as_root systemctl stop "$CAFFEINE_UNIT"
}

set_mode_state() {
    mkdir -p "${MODE_FILE%/*}"
    printf '%s\n' "$1" > "$MODE_FILE"
}

clear_mode_state() {
    rm -f "$MODE_FILE"
}

current_mode() {
    if [[ -r "$MODE_FILE" ]]; then
        cat "$MODE_FILE"
    elif is_prph_keyboard_filter_active; then
        echo prph
    elif is_inhibited "$KEYBOARD_DEVICE"; then
        echo untracked
    else
        echo normal
    fi
}

disable_internal_pointers() {
    local device

    if (( ${#POINTER_DEVICES[@]} == 0 )); then
        echo "Warning: internal touchpad was not found; skipped." >&2
    fi
    for device in "${POINTER_DEVICES[@]}"; do
        set_input_state "$device" 1 "internal pointer ($(read_device_name "$device"))"
    done
}

enable_internal_pointers() {
    local device

    for device in "${POINTER_DEVICES[@]}"; do
        set_input_state "$device" 0 "internal pointer ($(read_device_name "$device"))"
    done
}

enable_tailscale_ssh() {
    if ! command -v tailscale > /dev/null || ! command -v systemctl > /dev/null; then
        echo "Error: Tailscale is required for ssh mode." >&2
        return 1
    fi

    run_as_root systemctl start tailscaled
    run_as_root tailscale up
    run_as_root tailscale set --ssh
}

disable_tailscale_ssh() {
    command -v tailscale > /dev/null || return 0
    command -v systemctl > /dev/null || return 0
    systemctl is-active --quiet tailscaled 2>/dev/null || return 0
    run_as_root tailscale set --ssh=false
}

tailscale_ssh_state() {
    local prefs

    if ! command -v tailscale > /dev/null; then
        echo "UNAVAILABLE"
        return 0
    fi
    if ! prefs=$(tailscale debug prefs 2>/dev/null); then
        echo "DISCONNECTED"
    elif grep -Eq '"RunSSH"[[:space:]]*:[[:space:]]*true' <<< "$prefs"; then
        echo "ENABLED (TAILNET ONLY)"
    else
        echo "DISABLED"
    fi
}

enter_ssh_mode() {
    # Establish remote access before turning off any local controls.
    enable_tailscale_ssh
    enable_caffeine

    # In full headless mode the physical keyboard is inhibited completely.
    # The fingerprint/power button is a separate device and remains usable.
    set_input_state "$KEYBOARD_DEVICE" 1 "internal keyboard"
    stop_prph_keyboard_filter
    disable_internal_pointers
    disable_keyboard_backlight
    disable_display
    set_mode_state ssh

    echo "SSH mode enabled: Tailscale SSH is accepting tailnet-only connections."
    echo "Internal keyboard/touchpad and lights are off; caffeinated mode is active."
    if ! ac_is_online; then
        echo "Warning: charger power is not detected; the laptop is using its battery fallback." >&2
    fi
    show_power_source
}

enter_prph_mode() {
    # Validate the Escape-only filter before changing any current mode state.
    require_prph_keyboard_filter
    disable_tailscale_ssh
    restore_display
    disable_caffeine
    start_prph_keyboard_filter
    set_input_state "$KEYBOARD_DEVICE" 0 "internal keyboard"
    disable_internal_pointers
    disable_keyboard_backlight
    set_mode_state prph

    echo "Peripheral desktop mode enabled."
    echo "Internal touchpad and keyboard backlight are off; only Escape passes from the internal keyboard."
    echo "The fingerprint/power button remains usable, and inbound Tailscale SSH is off."
}

restore_normal_mode() {
    disable_tailscale_ssh
    stop_prph_keyboard_filter
    set_input_state "$KEYBOARD_DEVICE" 0 "internal keyboard"
    enable_internal_pointers
    restore_keyboard_backlight
    restore_display
    disable_caffeine
    clear_mode_state

    echo "Normal mode restored: internal input devices and saved light levels are enabled."
    echo "Inbound Tailscale SSH is disabled; outbound SSH remains available."
}

show_status() {
    local battery device mode pointer_state="NOT FOUND" keyboard_light="NOT FOUND"
    local tailscale_ip
    local all_pointer_devices_inhibited=1 path

    mode=$(current_mode)
    echo "Mode: ${mode^^}"

    if is_prph_keyboard_filter_active; then
        echo "Internal keyboard: ESCAPE ONLY"
    elif is_inhibited "$KEYBOARD_DEVICE"; then
        echo "Internal keyboard: DISABLED"
    else
        echo "Internal keyboard: ENABLED"
    fi

    if (( ${#POINTER_DEVICES[@]} > 0 )); then
        pointer_state="DISABLED"
        for device in "${POINTER_DEVICES[@]}"; do
            if ! is_inhibited "$device"; then
                all_pointer_devices_inhibited=0
            fi
        done
        (( all_pointer_devices_inhibited )) || pointer_state="ENABLED"
    fi
    echo "Internal touchpad: $pointer_state"

    if path=$(keyboard_backlight_path); then
        keyboard_light=$(cat "$path/brightness")
    fi
    echo "Keyboard backlight: $keyboard_light"

    if is_caffeinated; then
        echo "Caffeinated mode: ENABLED"
    else
        echo "Caffeinated mode: DISABLED"
    fi

    echo "Tailscale SSH: $(tailscale_ssh_state)"
    tailscale_ip=$(tailscale ip -4 2>/dev/null || true)
    [[ -n "$tailscale_ip" ]] && echo "Tailscale IPv4: $tailscale_ip"

    show_power_source
    if battery=$(battery_summary); then
        echo "Battery: $battery"
    else
        echo "Battery: NOT FOUND"
    fi
}

if [[ "${1:-}" == "mode" ]]; then
    [[ $# -eq 2 ]] || {
        usage
        exit 1
    }
    ACTION=$2
    case "$ACTION" in
        ssh|prph)
            ;;
        *)
            usage
            exit 1
            ;;
    esac
else
    [[ $# -eq 1 ]] || {
        usage
        exit 1
    }
    ACTION=$1
fi

case "$ACTION" in
    ssh|prph|normal|on|enable|off|disable|status)
        ;;
    *)
        usage
        exit 1
        ;;
esac

if ! KEYBOARD_DEVICE=$(find_internal_keyboard); then
    echo "Error: internal PS/2 keyboard not found." >&2
    exit 1
fi
mapfile -t POINTER_DEVICES < <(find_internal_pointer_devices)

case "$ACTION" in
    ssh|off|disable)
        enter_ssh_mode
        ;;
    prph)
        enter_prph_mode
        ;;
    normal|on|enable)
        restore_normal_mode
        ;;
    status)
        show_status
        ;;
esac
