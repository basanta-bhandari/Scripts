#!/usr/bin/env bash
#
# Restore a home backup archive onto a fresh install.
#
# Usage: sudo TARGET_USER=<username> ./restore-home-backup\(confidential\).sh <archive.tar>
#
# By default restores into /home/<username>. Pass a second argument to restore
# somewhere else (e.g. a scratch dir for inspection before committing).
#
set -euo pipefail

ARCHIVE="${1:-}"
# #laptop-data: supply the archive owner's account at runtime.
TARGET_USER="${TARGET_USER:?Set TARGET_USER to the archive owner username}"
TARGET_HOME="${2:-/home/${TARGET_USER}}"

if [[ -z "$ARCHIVE" ]]; then
    echo "Usage: sudo $0 <archive.tar> [target_dir]" >&2
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "Run as root (sudo) — needed to restore ownership/permissions correctly." >&2
    exit 1
fi

if [[ ! -f "$ARCHIVE" ]]; then
    echo "Archive not found: $ARCHIVE" >&2
    exit 1
fi

echo "Archive:     $ARCHIVE"
echo "Restoring to: $TARGET_HOME"
echo

if [[ -d "$TARGET_HOME" ]] && [[ -n "$(ls -A "$TARGET_HOME" 2>/dev/null)" ]]; then
    echo "WARNING: $TARGET_HOME already exists and is not empty."
    echo "Files from the archive will be extracted ON TOP of what's there."
    echo "Existing files with the same paths will be OVERWRITTEN."
    read -rp "Continue? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || exit 1
fi

mkdir -p "$TARGET_HOME"

echo "Extracting..."
tar -xapvf "$ARCHIVE" \
    --acls --xattrs \
    -C "$TARGET_HOME" 2>&1 | tail -n 50
# ^ tail -n 50 keeps the terminal from being flooded on huge archives while
#   still showing the tail end of the extraction. Remove the pipe entirely
#   if you want to see every file scroll by.

echo
echo "Extraction complete: $(date)"
echo
echo "IMPORTANT: ownership was preserved from the archive, but if the UID for"
echo "${TARGET_USER} differs on this fresh install, run the permissions helper next to fix it:"
echo "  sudo ./fix-restored-home-permissions\(confidential\).sh ${TARGET_USER} \"$TARGET_HOME\""
