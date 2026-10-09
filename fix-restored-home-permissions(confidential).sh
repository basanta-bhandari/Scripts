#!/usr/bin/env bash
#
# Fix ownership and permissions on a restored home
# directory. Useful after restoring archives, since UIDs/GIDs on a fresh
# install may not match the UIDs baked into the archive.
#
# Usage: sudo ./fix-restored-home-permissions\(confidential\).sh <username> [home_dir]
#
# Example: sudo ./fix-restored-home-permissions\(confidential\).sh <username> /home/<username>
#
set -euo pipefail

TARGET_USER="${1:-}"
TARGET_HOME="${2:-/home/${TARGET_USER}}"

if [[ -z "$TARGET_USER" ]]; then
    echo "Usage: sudo $0 <username> [home_dir]" >&2
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "Run as root (sudo)." >&2
    exit 1
fi

if ! id "$TARGET_USER" &>/dev/null; then
    echo "User '${TARGET_USER}' does not exist on this system yet." >&2
    echo "Create it first, e.g.:" >&2
    echo "  useradd -m -G wheel -s /bin/bash ${TARGET_USER}" >&2
    exit 1
fi

if [[ ! -d "$TARGET_HOME" ]]; then
    echo "Directory not found: $TARGET_HOME" >&2
    exit 1
fi

TARGET_UID="$(id -u "$TARGET_USER")"
TARGET_GID="$(id -g "$TARGET_USER")"

echo "User:      $TARGET_USER (uid=$TARGET_UID gid=$TARGET_GID)"
echo "Directory: $TARGET_HOME"
echo

CURRENT_OWNER="$(stat -c '%u:%g' "$TARGET_HOME")"
echo "Current top-level ownership: $CURRENT_OWNER"
read -rp "Recursively chown $TARGET_HOME to ${TARGET_USER}:${TARGET_USER}? [y/N] " ans
[[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted — no changes made."; exit 0; }

echo
echo "Fixing ownership..."
chown -R "${TARGET_UID}:${TARGET_GID}" "$TARGET_HOME"

echo "Fixing home directory permissions (700 on home dir itself)..."
chmod 700 "$TARGET_HOME"

# Common sensitive dirs that should be locked down regardless of what the
# archive preserved (belt and suspenders, e.g. if tar ran as a different
# user originally or perms got mangled in transit).
declare -A LOCKDOWN=(
    [".ssh"]="700"
    [".gnupg"]="700"
)

for dir in "${!LOCKDOWN[@]}"; do
    path="${TARGET_HOME}/${dir}"
    if [[ -d "$path" ]]; then
        echo "Locking down $path (${LOCKDOWN[$dir]})..."
        chmod "${LOCKDOWN[$dir]}" "$path"
        find "$path" -type f -exec chmod 600 {} \;
    fi
done

if [[ -f "${TARGET_HOME}/.ssh/authorized_keys" ]]; then
    chmod 600 "${TARGET_HOME}/.ssh/authorized_keys"
fi

echo
echo "Done: $(date)"
echo "Spot check a few paths if anything still looks off:"
echo "  ls -la \"$TARGET_HOME\" | head -20"
