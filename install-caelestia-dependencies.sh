#!/usr/bin/env bash
set -euo pipefail

# Caelestia dotfiles dependency installer for Arch-based systems

# --- Determine AUR helper ---
AUR_HELPER=""
for helper in paru yay; do
    if command -v "$helper" &>/dev/null; then
        AUR_HELPER="$helper"
        break
    fi
done

if [[ -z "$AUR_HELPER" ]]; then
    echo "No AUR helper (paru/yay) found. Install one first, e.g.:"
    echo '  git clone https://aur.archlinux.org/paru.git && cd paru && makepkg -si'
    exit 1
fi

echo "Using AUR helper: $AUR_HELPER"

# --- Official repo packages ---
PACMAN_PKGS=(
    ddcutil
    brightnessctl
    libcava
    networkmanager
    lm-sensors
    fish
    aubio
    libpipewire
    glibc
    qt6-declarative
    gcc-libs
    swappy
    libqalculate
    bash
    qt6-base
)

# --- AUR packages (not in official repos) ---
AUR_PKGS=(
    caelestia-cli
    quickshell-git
    material-symbols
    ttf-caskaydia-cove-nerd
)

echo "==> Installing official repo packages..."
sudo pacman -S --needed --noconfirm "${PACMAN_PKGS[@]}"

echo "==> Installing AUR packages..."
"$AUR_HELPER" -S --needed --noconfirm "${AUR_PKGS[@]}"

echo "==> Done! All dependencies installed."
