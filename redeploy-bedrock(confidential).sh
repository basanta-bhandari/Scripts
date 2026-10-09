#!/bin/sh
# Run from your home directory. #laptop-data
# Wipes every stale/duplicate Bedrock tree and deploys the one true zip.
set -e

ZIP="$HOME/Downloads/bedrock_TRUE_latest.zip"
ROOT="$HOME/Desktop/bedrock"

if [ ! -f "$ZIP" ]; then
  echo "!! Can't find $ZIP — check the filename/location and edit ZIP= above."
  exit 1
fi

echo "== killing any running qemu first (avoids file-lock weirdness) =="
pkill -f qemu-system-x86_64 2>/dev/null || true

echo "== removing stale/duplicate trees =="
rm -rf "$ROOT/src" "$ROOT/MAINBUILD" "$ROOT/limine"
rm -f "$ROOT/build.zig" "$ROOT/linker.ld" "$ROOT/run.sh" "$ROOT/changes_docs.md"
# docs/ is left alone deliberately — unrelated to this cleanup

echo "== extracting fresh copy =="
mkdir -p "$ROOT"
unzip -q -o "$ZIP" -d "$ROOT"

echo "== one-time limine setup =="
cd "$ROOT/src"
sh tools/setup-limine.sh

echo
echo "== verifying the deployed tree =="
ok=1
if [ -f kernel/drivers/font8x8.zig ]; then
  echo "  [ok] font8x8.zig present"
else
  echo "  [FAIL] font8x8.zig missing"
  ok=0
fi
if grep -q "qemu_debug" tools/dev.sh; then
  echo "  [ok] dev.sh is current"
else
  echo "  [FAIL] dev.sh is stale"
  ok=0
fi
if grep -q "const Color" kernel/drivers/display.zig; then
  echo "  [ok] Color fix present"
else
  echo "  [FAIL] Color fix missing"
  ok=0
fi

echo
if [ "$ok" = "1" ]; then
  echo "All good. Now sitting in: $ROOT/src"
  echo "Run: ./tools/dev.sh headless"
else
  echo "Something's off — don't trust this tree yet, paste the output back."
fi
