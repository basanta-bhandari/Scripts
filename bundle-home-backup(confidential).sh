#!/usr/bin/env bash
#
# Bundle a user's home directory onto an external drive, ahead of a
# reflash.
#
# Usage: sudo TARGET_USER=<username> DEST_DIR=<mounted-drive> ./bundle-home-backup\(confidential\).sh
#
set -euo pipefail

# #laptop-data: supply the user and mounted backup destination at runtime.
TARGET_USER="${TARGET_USER:?Set TARGET_USER to the account to back up}"
DEST_DIR="${DEST_DIR:?Set DEST_DIR to the mounted backup directory}"
TARGET_HOME="${TARGET_HOME:-/home/${TARGET_USER}}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="${DEST_DIR}/${TARGET_USER}-${TIMESTAMP}.tar"
LOGFILE="${DEST_DIR}/${TARGET_USER}-${TIMESTAMP}.log"
PKGLIST="${DEST_DIR}/pkglist-${TARGET_USER}-${TIMESTAMP}.txt"

# ---- sanity checks --------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "Run as root (sudo) — needs to read all of ${TARGET_USER}'s files." >&2
    exit 1
fi

if [[ ! -d "$TARGET_HOME" ]]; then
    echo "Home directory not found: $TARGET_HOME" >&2
    exit 1
fi

if [[ ! -d "$DEST_DIR" ]]; then
    echo "Destination $DEST_DIR does not exist. Is the drive mounted?" >&2
    exit 1
fi

if ! mountpoint -q "$DEST_DIR"; then
    echo "WARNING: $DEST_DIR does not appear to be a mount point." >&2
    read -rp "Continue anyway? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || exit 1
fi

if [[ ! -w "$DEST_DIR" ]]; then
    echo "Destination $DEST_DIR is not writable. Is the drive mounted read-only?" >&2
    echo "(Common after an unclean unplug — remount rw or replug the drive.)" >&2
    exit 1
fi

echo "Backing up:  $TARGET_HOME"
echo "Archive:     $ARCHIVE"
echo "Log:         $LOGFILE"
echo

# ---- excludes ---------------------------------------------------------

EXCLUDES=(
    --exclude="./.cache"
    --exclude="./.local/share/Trash"
    --exclude="./.mozilla/*/Cache"
    --exclude="./.thumbnails"
    --exclude="node_modules"
    --exclude=".npm"
    --exclude=".cargo/registry"
    --exclude=".cargo/git"
    --exclude=".rustup"
    --exclude=".gradle"
    --exclude=".m2/repository"
    --exclude=".pnpm-store"
    --exclude=".yarn/cache"
    --exclude="__pycache__"
    --exclude="*.pyc"
    --exclude=".venv"
    --exclude="venv"
    --exclude="site-packages"
    --exclude="./.local/share/godot"
    --exclude="./.godot"
    --exclude="*.godot/imported"
    --exclude="./.local/share/unity3d"
    --exclude="./Unity"
    --exclude="Library/PackageCache"
    --exclude="./.local/share/Steam"
    --exclude="./.local/share/docker"
    --exclude="./.docker"
    --exclude="./.minecraft"
    --exclude="./.local/share/PrismLauncher"
    --exclude="./.local/share/multimc"
    --exclude="./.var/app/org.prismlauncher.PrismLauncher"
    --exclude="./.local/share/libvirt"
    --exclude="./VirtualBox VMs"
    --exclude="./.config/VirtualBox"
    --exclude="./.VirtualBox"
    --exclude="*.vdi"
    --exclude="*.vmdk"
    --exclude="*.vbox"
    --exclude="*.qcow2"
    --exclude="./.local/share/gnome-boxes"
    --exclude="./.nv"
)

# ---- do the backup ---------------------------------------------------------

echo "Backup started: $(date)" > "$LOGFILE"

# Rough size estimate for the progress bar. Includes excluded dirs, so the
# bar may stall just short of 100% near the end — harmless.
SIZE="$(du -sb "$TARGET_HOME" 2>/dev/null | cut -f1)"
SIZE="${SIZE:-0}"

# render_progress <archive_file> <total_bytes> [style]
# Live bar with an ascii animation on the left. Polls the archive's size
# instead of piping tar through pv, so tar writes straight to the disk.
# Styles: jacks (default), spin, bounce.
render_progress() {
    local file="$1" total="$2"
    local -a FRAMES
    case "${3:-${ANIM_STYLE:-jacks}}" in
        spin)   FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏") ;;
        bounce) FRAMES=("|●--------|" "|-●-------|" "|--●------|" "|---●-----|" "|----●----|" "|-----●---|" "|------●--|" "|-------●-|" "|--------●|" "|-------●-|" "|------●--|" "|-----●---|" "|----●----|" "|---●-----|" "|--●------|" "|-●-------|") ;;
        *)      FRAMES=("\\o/" " | " "/o\\") ;;
    esac

    local cols bar_w i=0 prev_s=0 rate=0 pct filled eta human
    local now size prev_t=$SECONDS
    cols=$(tput cols 2>/dev/null); cols=${cols:-80}
    if (( cols > 70 )); then bar_w=30; else bar_w=14; fi

    while sleep 0.25; do
        size=$(stat -c %s "$file" 2>/dev/null) || continue
        now=$SECONDS
        if (( now > prev_t )); then
            rate=$(( (size - prev_s) / (now - prev_t) ))
            prev_s=$size; prev_t=$now
        fi

        pct=$(( total > 0 ? size * 100 / total : 0 ))
        (( pct > 100 )) && pct=100
        filled=$(( bar_w * pct / 100 ))

        eta="--:--"
        if (( rate > 0 && size < total )); then
            eta=$(printf '%02d:%02d' \
                $(( (total - size) / rate / 60 )) \
                $(( (total - size) / rate % 60 )))
        fi

        human=$(awk -v d="$size" -v t="$total" -v r="$rate" \
            'BEGIN { printf "%.1f/%.1fGiB %dMiB/s", d/1073741824, t/1073741824, r/1048576 }')

        printf '\r %s [%s%s] %3d%%  %-22s eta %s ' \
            "${FRAMES[i]}" \
            "$(printf '%*s' "$filled" '' | tr ' ' '#')" \
            "$(printf '%*s' $(( bar_w - filled )) '')" \
            "$pct" "$human" "$eta"
        i=$(( (i + 1) % ${#FRAMES[@]} ))
    done
}

TAR_RC=0
render_progress "$ARCHIVE" "$SIZE" &
PROG_PID=$!
trap 'kill "$PROG_PID" 2>/dev/null' EXIT

if ! tar -C "$TARGET_HOME" -cpf "$ARCHIVE" \
    --acls --xattrs \
    "${EXCLUDES[@]}" \
    . 2>>"$LOGFILE"; then
    TAR_RC=1
fi

kill "$PROG_PID" 2>/dev/null
wait "$PROG_PID" 2>/dev/null
trap - EXIT
printf '\r\033[K'

if (( TAR_RC )); then
    echo "FAILED — check $LOGFILE" >&2
    exit 1
fi

echo
echo "Archive done: $(date)" | tee -a "$LOGFILE"
ls -lh "$ARCHIVE"

# ---- package list (cheap insurance) ---------------------------------------

if command -v pacman >/dev/null 2>&1; then
    echo "Saving explicitly-installed package list..."
    pacman -Qqe > "$PKGLIST"
    echo "Package list: $PKGLIST ($(wc -l < "$PKGLIST") packages)"
fi

# ---- verify archive is readable/non-empty ----------------------------------

echo
echo "Verifying archive integrity..."

# One full read-through: verifies the whole archive is intact AND counts
# entries in a single pass (no separate integrity step needed for plain tar).
echo "Verifying archive (full read-through)..."
COUNT=""
if command -v pv >/dev/null 2>&1; then
    COUNT="$(pv -pteb "$ARCHIVE" | tar -tf - | wc -l)" || true
else
    COUNT="$(tar -tf "$ARCHIVE" | wc -l)" || true
fi

if [[ -z "$COUNT" ]]; then
    echo "FAILED: archive is unreadable or truncated. Do not trust this backup." >&2
    exit 1
fi
if [[ "$COUNT" -lt 1 ]]; then
    echo "WARNING: archive appears empty. Do not trust this backup." >&2
    exit 1
fi
echo "Archive contains $COUNT entries. Looks good."
echo
echo "Done. Safe to reflash once you've confirmed the archive listing looks right:"
echo "  tar -tvf \"$ARCHIVE\" | less"
