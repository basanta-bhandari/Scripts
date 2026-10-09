#!/usr/bin/env bash
# Prepare and sign a Linux flash-drive bundle. Run on the source machine.
set -euo pipefail

case "$(uname -s)" in Linux) ;; *) echo 'This helper supports Linux; use flasher author on Windows.' >&2; exit 1 ;; esac
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
dest="${1:-$repo/flasher-drive}"
binary="$repo/target/release/neonet"
if [[ ! -x "$binary" ]]; then
    echo 'Build first with cargo build --release --locked.' >&2
    exit 1
fi
if [[ -e "$dest/flashed.json" ]]; then
    echo 'A bundle already exists. Refresh it explicitly with flasher author --include-binary --ttl 600 --dir DRIVE.' >&2
    exit 1
fi
"$binary" flasher author --include-binary --ttl 600 --dir "$dest"
cat > "$dest/README.txt" <<'EOF'
NeoNet signed flash-drive setup (Windows and Linux)

Use only a drive and executable from a source you trust. A self-signature
checks integrity; it does not establish the author's trustworthiness.

On a matching target OS/CPU, run the bundled executable in bin/OS-ARCH/:
  neonet flasher adopt --dir DRIVE
Confirm the source identity. This records trust, installs if missing, and
writes setup-receipt.json. --yes explicitly approves unattended adoption.

Return the drive to the source and run:
  neonet flasher complete --dir DRIVE
Complete within the 600-second setup window. A token can be completed once.
Refresh an expired bundle on the source with:
  neonet flasher author --include-binary --ttl 600 --dir DRIVE

Nothing runs automatically when the drive is plugged in. An OS/CPU-specific
executable must be built on the corresponding platform.
EOF
printf 'Signed drive ready at %s; adopt and return it within 600 seconds.\n' "$dest"
