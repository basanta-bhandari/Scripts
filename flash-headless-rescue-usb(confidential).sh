#!/usr/bin/env bash
set -euo pipefail

# #laptop-data: supply the target USB identity and image details at runtime.
device="${USB_DEVICE:?Set USB_DEVICE to the target USB block device}"
expected_serial="${USB_SERIAL:?Set USB_SERIAL to the target USB serial number}"
expected_model="${USB_MODEL:?Set USB_MODEL to the target USB model}"
image="${IMAGE_PATH:?Set IMAGE_PATH to the ISO image}"
expected_sha256="${IMAGE_SHA256:?Set IMAGE_SHA256 to the ISO SHA-256 digest}"

[[ "$(id -u)" == 0 ]] || { echo "This writer must run as root." >&2; exit 1; }
[[ -b "$device" ]] || { echo "$device is not a block device." >&2; exit 1; }

actual_path="$(lsblk -dn -o PATH "$device" | xargs)"
actual_size="$(lsblk -dn -o SIZE "$device" | xargs)"
actual_transport="$(lsblk -dn -o TRAN "$device" | xargs)"
actual_removable="$(lsblk -dn -o RM "$device" | xargs)"
actual_readonly="$(lsblk -dn -o RO "$device" | xargs)"
actual_model="$(lsblk -dn -o MODEL "$device" | xargs)"
actual_serial="$(lsblk -dn -o SERIAL "$device" | xargs)"

[[ "$actual_path" == "$device" ]]
[[ "$actual_transport" == usb ]]
[[ "$actual_removable" == 1 ]]
[[ "$actual_readonly" == 0 ]]
[[ "$actual_model" == "$expected_model" ]]
[[ "$actual_serial" == "$expected_serial" ]]

if lsblk -nrpo MOUNTPOINTS "$device" | grep -q '[^[:space:]]'; then
  echo "Refusing to flash because a USB partition is mounted." >&2
  exit 1
fi

printf '%s  %s\n' "$expected_sha256" "$image" | sha256sum -c -

echo "Writing $image to $device ($actual_size, $actual_model, serial $actual_serial)..."
dd if="$image" of="$device" bs=4M conv=fsync status=progress
sync

image_size="$(stat -c %s "$image")"
echo "Reading back and comparing $image_size bytes..."
cmp -n "$image_size" "$image" "$device"
echo "USB flash and byte-for-byte verification completed successfully."
