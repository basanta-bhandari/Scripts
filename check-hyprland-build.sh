#!/bin/bash
# Check Hyprland build progress

TERMINAL_ID="ee12f97e-38bf-45f0-8807-ea286a99edf2"

echo "=== Hyprland Build Status ==="
echo "Time: $(date)"
echo ""

# Check if build is still running
if ps aux | grep -q "install.sh\|meson\|ninja" | grep -v grep; then
    echo "✓ Build process is RUNNING"
    ps aux | grep -E "install.sh|meson|ninja" | grep -v grep
else
    echo "✗ Build process appears to be STOPPED"
fi

echo ""
echo "=== Recently modified files in /usr/local ==="
ls -lt /usr/local/bin /usr/local/lib 2>/dev/null | head -5

echo ""
echo "=== Build logs ==="
tail -20 ~/Debian-Hyprland/Install-Logs/*.log 2>/dev/null || echo "No logs found yet"
