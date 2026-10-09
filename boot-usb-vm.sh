#!/usr/bin/env bash
# Boot a VirtualBox VM from a physical, pre-flashed USB drive.
#
# Usage:
#   ./boot-usb-vm.sh [--efi] [--headless] [/dev/sdX] [vm-name]
#
# Requires write access to the raw device: either run as root
# (with VBOX_USER_HOME pointed at your config) or be in the
# 'disk' and 'vboxusers' groups.

set -euo pipefail

VBOX="${VBOXMANAGE:-VBoxManage}"
EFI=0
HEADLESS=0
DEVICE=""
VM_NAME=""

for arg in "$@"; do
  case "$arg" in
    --efi) EFI=1 ;;
    --headless) HEADLESS=1 ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *)
      if [[ -z "$DEVICE" && -b "/dev/$arg" ]]; then
        DEVICE="/dev/${arg#/dev/}"
      elif [[ -z "$VM_NAME" ]]; then
        VM_NAME="$arg"
      fi ;;
  esac
done

command -v "$VBOX" >/dev/null 2>&1 || { echo "Error: VBoxManage not found." >&2; exit 1; }

if [[ -z "$DEVICE" ]]; then
  echo "Removable disks detected:"
  lsblk -dpno NAME,RM,SIZE,MODEL | awk '$2==1'
  read -rp "Device to boot from (e.g. /dev/sdb): " DEVICE
fi

[[ -b "$DEVICE" ]] || { echo "Error: no such block device: $DEVICE" >&2; exit 1; }

if [[ ! -r "$DEVICE" || ! -w "$DEVICE" ]]; then
  cat >&2 <<EOF

$DEVICE is not accessible by user $(whoami). Fix with either:
  sudo usermod -aG disk,vboxusers $USER     # then log out and back in
or rerun as root keeping your VM config:
  sudo VBOX_USER_HOME='$HOME/.config/VirtualBox' $0 $*
EOF
  exit 1
fi

echo
echo "Target : $DEVICE ($(lsblk -dno SIZE,MODEL "$DEVICE"))"
echo "Warning: the guest gets RAW access and can rewrite this entire disk."
read -rp "Continue? [y/N] " ans
[[ "${ans,,}" == "y" ]] || exit 1

MOUNTED="$(lsblk -lno MOUNTPOINT "$DEVICE" | sed '/^$/d')"
if [[ -n "$MOUNTED" ]]; then
  while read -r m; do echo "Unmounting $m"; umount "$m"; done <<<"$MOUNTED"
fi
REMAINING="$(lsblk -lno MOUNTPOINT "$DEVICE" | sed '/^$/d')"
[[ -z "$REMAINING" ]] || { echo "Error: still mounted/active: $REMAINING (try swapoff)" >&2; exit 1; }

VM_NAME="${VM_NAME:-USB-Boot}"
VMDK_DIR="$HOME/.vbox-usb"
mkdir -p "$VMDK_DIR"
VMDK="$VMDK_DIR/$VM_NAME.vmdk"
rm -f "$VMDK"
"$VBOX" internalcommands createrawvmdk -filename "$VMDK" -rawdisk "$DEVICE" >/dev/null

if ! "$VBOX" showvminfo "$VM_NAME" >/dev/null 2>&1; then
  echo "Creating VM '$VM_NAME' ..."
  "$VBOX" createvm --name "$VM_NAME" --register >/dev/null
  EXTRA=()
  (( EFI )) && EXTRA+=(--firmware efi)
  "$VBOX" modifyvm "$VM_NAME" \
    --memory 2048 --cpus 2 --vram 16 \
    --graphicscontroller vmsvga \
    --nic1 nat --audio none --usb off \
    --boot1 disk --boot2 none --boot3 none --boot4 none \
    "${EXTRA[@]}" >/dev/null
elif (( EFI )); then
  "$VBOX" modifyvm "$VM_NAME" --firmware efi
fi

"$VBOX" storagectl "$VM_NAME" --name SATA --add sata --controller IntelAhci --portcount 2 >/dev/null 2>&1 || true
"$VBOX" storageattach "$VM_NAME" --storagectl SATA --port 0 --device 0 --type hdd --medium "$VMDK" >/dev/null

TYPE=gui
(( HEADLESS )) && TYPE=headless
echo "Starting '$VM_NAME' from $DEVICE ..."
exec "$VBOX" startvm "$VM_NAME" --type "$TYPE"
