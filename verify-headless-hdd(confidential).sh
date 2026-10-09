#!/usr/bin/env bash
set -euo pipefail

export PATH=/usr/sbin:/usr/bin:/sbin:/bin

# #laptop-data: use the same disk and host values supplied to the preparation script.
device="${HDD_DEVICE:?Set HDD_DEVICE to the target disk}"
root_partition="${HDD_ROOT_PARTITION:?Set HDD_ROOT_PARTITION to the root partition}"
efi_partition="${HDD_EFI_PARTITION:?Set HDD_EFI_PARTITION to the EFI partition}"
bios_partition="${HDD_BIOS_PARTITION:?Set HDD_BIOS_PARTITION to the BIOS boot partition}"
expected_bytes="${HDD_BYTES:?Set HDD_BYTES to the expected disk size in bytes}"
expected_model="${HDD_MODEL:?Set HDD_MODEL to the expected disk model}"
expected_serial="${HDD_SERIAL:?Set HDD_SERIAL to the expected disk serial}"
login_user="${TARGET_LOGIN_USER:?Set TARGET_LOGIN_USER to the SSH username}"
hostname="${TARGET_HOSTNAME:?Set TARGET_HOSTNAME to the prepared hostname}"
target="${TARGET_MOUNT:-/mnt/headless-target-verify}"

cleanup() {
    set +e
    umount -R "$target" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

[[ $(id -u) -eq 0 ]] || { echo "Run through pkexec." >&2; exit 1; }
[[ $(blockdev --getsize64 "$device") == "$expected_bytes" ]]
[[ $(lsblk -dn -o MODEL "$device" | xargs) == "$expected_model" ]]
[[ $(lsblk -dn -o SERIAL "$device" | xargs) == "$expected_serial" ]]
[[ $(lsblk -dn -o PARTTYPE "$bios_partition" | tr '[:upper:]' '[:lower:]') == \
    21686148-6449-6e6f-744e-656564454649 ]]

install -d -m 0755 "$target"
mount -o ro "$root_partition" "$target"
mount -o ro "$efi_partition" "$target/boot/efi"

test -s "$target/boot/efi/EFI/BOOT/BOOTX64.EFI"
test -s "$target/boot/grub/grub.cfg"
test -s "$target/home/$login_user/.ssh/authorized_keys"
test -s "$target/etc/ssh/sshd_config.d/90-headless.conf"
test -s "$target/etc/NetworkManager/system-connections/headless-wired.nmconnection"
test "$(cat "$target/etc/hostname")" = "$hostname"

echo "Disk identity: verified"
echo "Root filesystem: verified"
echo "Legacy BIOS boot partition: verified"
echo "UEFI fallback bootloader: verified"
echo "GRUB configuration: verified"
echo "SSH key and policy: verified"
echo "Wired DHCP profile: verified"
echo "Hostname: $hostname"
ssh-keygen -lf "$target/home/$login_user/.ssh/authorized_keys"
ssh-keygen -lf "$target/etc/ssh/ssh_host_ed25519_key.pub"
