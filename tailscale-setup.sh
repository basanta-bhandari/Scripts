#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: ./tailscale-setup.sh [--reset]

Installs and starts Tailscale, then opens its interactive authentication page
in the default browser. By default, existing Tailscale preferences are
preserved. Pass --reset to replace them with Tailscale's defaults.
EOF
}

open_auth_page() {
    local url=$1

    echo
    echo "Tailscale authentication page: $url"

    if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
        echo "No graphical session was detected; open the URL manually."
        return 0
    fi

    if command -v xdg-open >/dev/null 2>&1; then
        nohup xdg-open "$url" >/dev/null 2>&1 &
        disown "$!" 2>/dev/null || true
        echo "Opened the authentication page in your default browser."
    elif command -v gio >/dev/null 2>&1; then
        nohup gio open "$url" >/dev/null 2>&1 &
        disown "$!" 2>/dev/null || true
        echo "Opened the authentication page in your default browser."
    else
        echo "No browser opener was found; open the URL manually."
    fi
}

interactive_login() {
    local line
    local -a login_args=(up)

    if [[ "$reset_settings" == true ]]; then
        login_args+=(--reset)
    fi

    # A bare `tailscale up` preserves every existing non-default preference,
    # including --operator and --ssh. Read its output as a stream, launch the
    # browser when an authentication URL appears, then wait for completion.
    sudo tailscale "${login_args[@]}" | while IFS= read -r line; do
        echo "$line"
        if [[ "$line" =~ (https://login\.tailscale\.com/[^[:space:]\"]+) ]]; then
            open_auth_page "${BASH_REMATCH[1]}"
        fi
    done
}

reset_settings=false
case "${1:-}" in
    "") ;;
    --reset) reset_settings=true ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

if ! command -v curl >/dev/null 2>&1; then
    echo "Error: curl is required." >&2
    exit 1
fi

if ! command -v tailscale >/dev/null 2>&1; then
    echo "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
fi

if command -v systemctl >/dev/null 2>&1; then
    echo "Starting tailscaled..."
    sudo systemctl enable --now tailscaled
fi

interactive_login

echo
echo "Tailscale is connected:"
tailscale status
echo
echo "IPv4 address: $(tailscale ip -4)"
