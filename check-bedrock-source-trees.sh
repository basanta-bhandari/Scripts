for d in ~/Desktop/bedrock/src ~/Desktop/bedrock/MAINBUILD ~/Desktop/bedrock/src/bundle; do
  echo "=== $d ==="
  [ -f "$d/kernel/drivers/font8x8.zig" ] && echo "  has font8x8.zig (framebuffer work)" || echo "  MISSING font8x8.zig"
  [ -f "$d/tools/dev.sh" ] && grep -q "qemu_debug" "$d/tools/dev.sh" 2>/dev/null && echo "  dev.sh is current" || echo "  dev.sh missing/stale"
  grep -q "const Color" "$d/kernel/drivers/display.zig" 2>/dev/null && echo "  Color fix present" || echo "  Color fix MISSING"
done
