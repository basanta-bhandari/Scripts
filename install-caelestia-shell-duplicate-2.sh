#!/usr/bin/env bash
#
# Manual install/build script for caelestia-shell on CachyOS
# (Arch-based — same pacman/AUR workflow, just with CachyOS repos on top)
#
# This does the "manual installation" path from the README:
#   - installs runtime deps (pacman + AUR)
#   - installs build deps (cmake, ninja)
#   - clones caelestia-dots/shell into $XDG_CONFIG_HOME/quickshell/caelestia
#   - builds it with cmake/ninja and installs it
#
set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Sanity checks
# ---------------------------------------------------------------------------

if [[ $EUID -eq 0 ]]; then
    echo "Don't run this as root — it calls sudo where needed." >&2
    exit 1
fi

AUR_HELPER=""
for helper in paru yay; do
    if command -v "$helper" &>/dev/null; then
        AUR_HELPER="$helper"
        break
    fi
done

if [[ -z "$AUR_HELPER" ]]; then
    echo "No AUR helper found (paru/yay). Install one first, e.g.:"
    echo '  git clone https://aur.archlinux.org/paru.git && cd paru && makepkg -si'
    exit 1
fi

echo "==> Using AUR helper: $AUR_HELPER"

# ---------------------------------------------------------------------------
# 1. Runtime dependencies
# ---------------------------------------------------------------------------

# Official repo packages (CachyOS repos + core/extra all cover these)
PACMAN_PKGS=(
    ddcutil
    brightnessctl
    cava            # provides libcava
    networkmanager
    lm_sensors      # note the underscore
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

# Build dependencies
BUILD_PKGS=(
    base-devel
    cmake
    ninja
    git
)

# AUR-only packages
AUR_PKGS=(
    caelestia-cli
    quickshell-git      # must be the git version, not the tagged one
    material-symbols
    ttf-caskaydia-cove-nerd
)

echo "==> Installing official repo + build packages..."
sudo pacman -S --needed --noconfirm "${PACMAN_PKGS[@]}" "${BUILD_PKGS[@]}"

echo "==> Installing AUR packages..."
"$AUR_HELPER" -S --needed --noconfirm "${AUR_PKGS[@]}"

# ---------------------------------------------------------------------------
# 2. Clone the shell repo
# ---------------------------------------------------------------------------

XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
QS_DIR="$XDG_CONFIG_HOME/quickshell"
TARGET_DIR="$QS_DIR/caelestia"

mkdir -p "$QS_DIR"

if [[ -d "$TARGET_DIR/.git" ]]; then
    echo "==> caelestia-shell already cloned at $TARGET_DIR, pulling latest..."
    git -C "$TARGET_DIR" pull
else
    echo "==> Cloning caelestia-shell into $TARGET_DIR..."
    git clone https://github.com/caelestia-dots/shell.git "$TARGET_DIR"
fi

cd "$TARGET_DIR"

# ---------------------------------------------------------------------------
# 3. Build and install
# ---------------------------------------------------------------------------

echo "==> Configuring build..."
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/

echo "==> Building..."
cmake --build build

echo "==> Installing (requires sudo)..."
sudo cmake --install build

echo
echo "==> Done. Start the shell with:"
echo "      caelestia shell -d"
echo "    or:"
echo "      qs -c caelestia"
