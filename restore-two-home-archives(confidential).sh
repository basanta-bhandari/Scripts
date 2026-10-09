#!/usr/bin/env bash
#
# Combine one user's data from an old archive with another user's data from a
# new home backup archive, restoring both onto a
# fresh /home without needing to mutate either archive in place.
#
# This does NOT edit either source archive. It extracts the first user from the old
# archive and the second user from the new one, straight into their respective /home
# dirs on the fresh install. Safer than tar --delete/--append tricks.
#
# Usage:
#   sudo OLD_USER=<old-user> NEW_USER=<new-user> ./restore-two-home-archives\(confidential\).sh <old-archive.tar> <new-archive.tar>
#
set -euo pipefail

OLD_ARCHIVE="${1:-}"
NEW_ARCHIVE="${2:-}"
# #laptop-data: supply both account names at runtime.
OLD_USER="${OLD_USER:?Set OLD_USER to the account in the old archive}"
NEW_USER="${NEW_USER:?Set NEW_USER to the account in the new archive}"
LOGFILE="/tmp/merge-$(date +%Y%m%d-%H%M%S).log"

if [[ -z "$OLD_ARCHIVE" || -z "$NEW_ARCHIVE" ]]; then
    echo "Usage: sudo OLD_USER=<old-user> NEW_USER=<new-user> $0 <old-archive.tar> <new-archive.tar>" >&2
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "Run as root (sudo) — needed to restore ownership correctly." >&2
    exit 1
fi

for f in "$OLD_ARCHIVE" "$NEW_ARCHIVE"; do
    if [[ ! -f "$f" ]]; then
        echo "File not found: $f" >&2
        exit 1
    fi
done

echo "Old (combined) archive: $OLD_ARCHIVE   -> will pull $OLD_USER/ entries only"
echo "New ($NEW_USER) archive: $NEW_ARCHIVE   -> restored in full"
echo "Log:                    $LOGFILE"
echo

# ---- detect the old user's path prefix inside the OLD archive -------------

echo "Inspecting old archive for $OLD_USER's path prefix..."
SAMPLE="$(tar -tf "$OLD_ARCHIVE" | grep -m1 -F "/${OLD_USER}/" || true)"
if [[ -z "$SAMPLE" ]]; then
    SAMPLE="$(tar -tf "$OLD_ARCHIVE" | grep -m1 -F "${OLD_USER}/" || true)"
fi

if [[ -z "$SAMPLE" ]]; then
    echo "Could not find any '$OLD_USER/' entries in $OLD_ARCHIVE." >&2
    echo "Check the layout manually with: tar -tf \"$OLD_ARCHIVE\" | less" >&2
    exit 1
fi

# NOTE: this deliberately anchors to the FIRST username directory in the entry.
PREFIX="${SAMPLE%%${OLD_USER}/*}${OLD_USER}/"
echo "Detected $OLD_USER prefix: '${PREFIX}'"
echo "Sample entry: $SAMPLE"
echo
read -rp "Does this look correct? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborting — inspect the archive and re-run."; exit 1; }

# ---- restore the old user from the OLD archive -----------------------------

OLD_HOME="/home/$OLD_USER"
mkdir -p "$OLD_HOME"

echo
echo "[1/2] Extracting $OLD_USER's files from $OLD_ARCHIVE ..."
echo "Extraction started: $(date)" > "$LOGFILE"

tar -xapvf "$OLD_ARCHIVE" \
    --acls --xattrs \
    --wildcards "${PREFIX}*" \
    --strip-components="$(echo "$PREFIX" | tr -cd '/' | wc -c)" \
    -C "$OLD_HOME" 2>>"$LOGFILE" | tail -n 30

echo "$OLD_USER restored to $OLD_HOME"

# ---- restore the new user from the NEW archive -----------------------------

NEW_HOME="/home/$NEW_USER"
mkdir -p "$NEW_HOME"

echo
echo "[2/2] Extracting $NEW_USER's files from $NEW_ARCHIVE ..."

tar -xapvf "$NEW_ARCHIVE" \
    --acls --xattrs \
    -C "$NEW_HOME" 2>>"$LOGFILE" | tail -n 30

echo "$NEW_USER restored to $NEW_HOME"

echo
echo "Merge complete: $(date)" | tee -a "$LOGFILE"
echo
echo "Next: run the permissions helper to fix ownership for both users, e.g.:"
echo "  sudo ./fix-restored-home-permissions\(confidential\).sh $OLD_USER $OLD_HOME"
echo "  sudo ./fix-restored-home-permissions\(confidential\).sh $NEW_USER $NEW_HOME"
echo
echo "NOTE: neither source archive was modified. Both are still intact if"
echo "anything here needs to be re-run."
