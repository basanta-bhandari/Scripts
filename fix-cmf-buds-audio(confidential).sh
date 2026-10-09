#!/bin/bash
# Fix CMF Buds Pro 2 A2DP audio routing on your laptop.
# Run as your desktop user. #laptop-data

BLUETOOTH_CARD="${BLUETOOTH_CARD:?Set BLUETOOTH_CARD to your bluez_card ID (#laptop-data)}"

echo ">>> Checking pipewire-audio..."
if ! dpkg -l | grep -q pipewire-audio; then
    echo ">>> Installing pipewire-audio..."
    sudo apt install -y pipewire-audio
else
    echo ">>> pipewire-audio already installed, skipping."
fi

echo ">>> Restarting PipeWire stack..."
systemctl --user restart pipewire wireplumber pipewire-pulse
sleep 2

echo ">>> Setting CMF Buds Pro 2 to A2DP..."
pactl set-card-profile "$BLUETOOTH_CARD" a2dp-sink

if [ $? -eq 0 ]; then
    echo "✓ Done! Audio should now route through your buds."
else
    echo "✗ Failed. Make sure your buds are connected first, then retry."
fi

