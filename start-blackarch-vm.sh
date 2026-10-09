#!/usr/bin/env bash
set -euo pipefail

VM_NAME="BlackArch"
KVER="$(uname -r)"

confirm() {
  read -rp "$1 [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

echo "==> Kernel: $KVER"

# 1. Ensure headers match running kernel
if ! pacman -Qq linux-headers &>/dev/null && ! pacman -Qq linux-cachyos-headers &>/dev/null; then
  if confirm "linux headers not found — install now (needed to build vboxdrv)?"; then
    sudo pacman -S --needed linux-headers
  else
    echo "Cannot proceed without headers. Exiting."
    exit 1
  fi
fi

# 2. Ensure virtualbox-host-dkms is installed (custom kernel -> dkms, not host-modules-arch)
if ! pacman -Qq virtualbox-host-dkms &>/dev/null; then
  if confirm "virtualbox-host-dkms not installed — install now?"; then
    sudo pacman -S --needed virtualbox-host-dkms
  else
    echo "Cannot proceed without virtualbox-host-dkms. Exiting."
    exit 1
  fi
fi

# 3. Check dkms build status for this kernel
if ! dkms status | grep -q "vboxhost.*${KVER}.*installed"; then
  echo "==> vboxhost module not built for $KVER, forcing rebuild..."
  sudo dkms autoinstall
fi

# 4. Load kernel module if not loaded
if ! lsmod | grep -q '^vboxdrv'; then
  if confirm "vboxdrv not loaded — attempt modprobe now (non-destructive)?"; then
    sudo modprobe vboxdrv || true
  fi
fi

# 5. Final check — if still not loaded, this needs a reboot (serious/disruptive, ask)
if ! lsmod | grep -q '^vboxdrv'; then
  echo "!! vboxdrv still not loaded after modprobe."
  if confirm "A reboot is likely required to load the new module. Reboot now?"; then
    sudo reboot
    exit 0
  else
    echo "Skipping reboot. Re-run this script after rebooting."
    exit 1
  fi
fi

echo "==> vboxdrv is loaded."
lsmod | grep vboxdrv

# 6. Start the VM (safe, non-destructive)
echo "==> Starting VM: $VM_NAME"
VBoxManage startvm "$VM_NAME" --type gui
