#!/usr/bin/env bash
set -e

echo "== Checking for Python3/pip =="
if ! command -v python3 &>/dev/null; then
  echo "python3 not found — installing..."
  if command -v dnf &>/dev/null; then
    sudo dnf install -y python3 python3-pip
  elif command -v pacman &>/dev/null; then
    sudo pacman -S --noconfirm python python-pip
  elif command -v apt &>/dev/null; then
    sudo apt update && sudo apt install -y python3 python3-pip
  else
    echo "Unsupported package manager — install python3 + pip manually." >&2
    exit 1
  fi
fi

if ! command -v pip3 &>/dev/null; then
  python3 -m ensurepip --upgrade
fi

echo "== Installing PlatformIO =="
pip3 install --break-system-packages -r requirements.txt

echo "== Installing PlatformIO udev rules (needed for USB access without sudo) =="
if [ ! -f /etc/udev/rules.d/99-platformio-udev.rules ]; then
  UDEV_URL="https://raw.githubusercontent.com/platformio/platformio-core/develop/platformio/assets/system/99-platformio-udev.rules"
  if curl -fsSL "$UDEV_URL" -o /tmp/99-platformio-udev.rules; then
    sudo cp /tmp/99-platformio-udev.rules /etc/udev/rules.d/99-platformio-udev.rules
    sudo udevadm control --reload-rules
    sudo udevadm trigger
  else
    echo "!! Could not download udev rules (URL may have moved again)."
    echo "!! Falling back to dialout/plugdev group membership only, which is"
    echo "!! usually sufficient on its own for a personal ESP32 dev board."
  fi
fi

echo "== Adding $USER to serial-access group (dialout/plugdev/uucp, whichever exists) =="
NEEDS_RELOGIN=0
for grp in dialout plugdev uucp; do
  if getent group "$grp" &>/dev/null && ! groups "$USER" | grep -q "$grp"; then
    sudo usermod -aG "$grp" "$USER"
    NEEDS_RELOGIN=1
  fi
done
if [ "$NEEDS_RELOGIN" -eq 1 ]; then
  echo ""
  echo "!! Group membership changed. This requires a logout/reboot to take effect."
  echo "!! Re-run this script after logging back in."
  exit 0
fi

echo "== Detecting ESP32 USB port =="
ESP_PORT=$(ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null | head -n1 || true)
if [ -z "$ESP_PORT" ]; then
  echo "No /dev/ttyUSB* or /dev/ttyACM* device found — plug in the ESP32 and retry." >&2
  exit 1
fi
echo "Using port: $ESP_PORT"

echo "== Building firmware =="
pio run

echo "== Uploading firmware (main.cpp) =="
pio run -t upload --upload-port "$ESP_PORT"

echo "== Uploading filesystem (data/index.html) =="
pio run -t uploadfs --upload-port "$ESP_PORT"

echo "== Opening serial monitor (Ctrl+C to exit) =="
pio device monitor --port "$ESP_PORT"
