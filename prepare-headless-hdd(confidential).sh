#!/usr/bin/env bash
set -euo pipefail

export PATH=/usr/sbin:/usr/bin:/sbin:/bin

# #laptop-data #ssh-key: supply and verify these values before running.
device="${HDD_DEVICE:?Set HDD_DEVICE to the target disk}"
root_partition="${HDD_ROOT_PARTITION:?Set HDD_ROOT_PARTITION to the root partition}"
efi_partition="${HDD_EFI_PARTITION:?Set HDD_EFI_PARTITION to the EFI partition}"
bios_partition="${HDD_BIOS_PARTITION:?Set HDD_BIOS_PARTITION to the BIOS boot partition}"
expected_bytes="${HDD_BYTES:?Set HDD_BYTES to the expected disk size in bytes}"
expected_model="${HDD_MODEL:?Set HDD_MODEL to the expected disk model}"
expected_serial="${HDD_SERIAL:?Set HDD_SERIAL to the expected disk serial}"
expected_os="${HDD_OS:?Set HDD_OS to the existing OS name}"
target="${TARGET_MOUNT:-/mnt/headless-target}"
project="${PROJECT_DIR:?Set PROJECT_DIR to the project backup directory}"
public_key="${SSH_PUBLIC_KEY_PATH:?Set SSH_PUBLIC_KEY_PATH to your public key path}"
hostname="${TARGET_HOSTNAME:?Set TARGET_HOSTNAME for the prepared machine}"
login_user="${TARGET_LOGIN_USER:?Set TARGET_LOGIN_USER for SSH access}"
key_fingerprint="${SSH_KEY_FINGERPRINT:?Set SSH_KEY_FINGERPRINT to the public-key fingerprint}"

mounted=0
resolv_changed=0
resolv_link=
resolv_regular_backup=
restore_resolv() {
    if (( resolv_changed )) && [[ -d $target/etc ]]; then
        rm -f "$target/etc/resolv.conf"
        if [[ -n $resolv_link ]]; then
            ln -s "$resolv_link" "$target/etc/resolv.conf"
        elif [[ -n $resolv_regular_backup && -f $resolv_regular_backup ]]; then
            cp -a "$resolv_regular_backup" "$target/etc/resolv.conf"
        fi
        resolv_changed=0
    fi
}
cleanup() {
    set +e
    if (( mounted )); then
        restore_resolv
        sync
        umount -R "$target" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

[[ $(id -u) -eq 0 ]] || fail "Run this script through pkexec."
[[ -b $device ]] || fail "$device is not a block device."
[[ -b $root_partition && -b $efi_partition ]] || fail "Expected partitions are missing."

actual_bytes=$(blockdev --getsize64 "$device")
actual_model=$(lsblk -dn -o MODEL "$device" | xargs)
actual_serial=$(lsblk -dn -o SERIAL "$device" | xargs)
root_source=$(findmnt -n -o SOURCE /)

[[ $actual_bytes == "$expected_bytes" ]] || fail "Disk size mismatch: $actual_bytes"
[[ $actual_model == "$expected_model" ]] || fail "Disk model mismatch: $actual_model"
[[ $actual_serial == "$expected_serial" ]] || fail "Disk serial mismatch: $actual_serial"
[[ $root_source != "$device"* ]] || fail "Refusing to modify the running system disk."

if lsblk -nrpo MOUNTPOINTS "$device" | grep -q '[^[:space:]]'; then
    fail "A target HDD partition is mounted. Unmount it before retrying."
fi

[[ -r $public_key ]] || fail "Public key not found: $public_key"
actual_fingerprint=$(ssh-keygen -lf "$public_key" | awk '{print $2}')
[[ $actual_fingerprint == "$key_fingerprint" ]] || fail "SSH public-key fingerprint changed."

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
backup_dir="$project/backups/$timestamp"
install -d -m 0700 "$backup_dir"
sfdisk --dump "$device" >"$backup_dir/partition-table.sfdisk"

echo "Validated target: $device ($actual_model, serial $actual_serial, $actual_bytes bytes)"
echo "Partition-table backup: $backup_dir/partition-table.sfdisk"

# The disk is GPT. Add a tiny BIOS boot partition in the already-unused gap
# before partition 1, while retaining the existing EFI and Mint partitions.
if [[ ! -b $bios_partition ]]; then
    parted -s --align none "$device" unit s mkpart bios_grub 34 2047
    parted -s "$device" set 3 bios_grub on
    partprobe "$device"
    udevadm settle
fi

[[ -b $bios_partition ]] || fail "BIOS boot partition was not created."
bios_parttype=$(lsblk -dn -o PARTTYPE "$bios_partition" | tr '[:upper:]' '[:lower:]')
[[ $bios_parttype == 21686148-6449-6e6f-744e-656564454649 ]] \
    || fail "Partition 3 exists but is not a BIOS boot partition."

install -d -m 0755 "$target"
mount "$root_partition" "$target"
mounted=1

grep -q "NAME=\"$expected_os\"" "$target/usr/lib/os-release" \
    || fail "Unexpected operating system on target root filesystem."

install -d -m 0755 "$target/boot/efi"
mount "$efi_partition" "$target/boot/efi"

# Preserve the small set of files this script intentionally changes.
for path in \
    etc/passwd etc/group etc/shadow etc/gshadow etc/hostname etc/hosts \
    etc/default/grub etc/ssh/sshd_config etc/fstab; do
    if [[ -e $target/$path || -L $target/$path ]]; then
        install -d "$backup_dir/$(dirname "$path")"
        cp -a "$target/$path" "$backup_dir/$path"
    fi
done
if [[ -d $target/boot/efi/EFI ]]; then
    cp -a "$target/boot/efi/EFI" "$backup_dir/EFI-before"
fi

mount --rbind /dev "$target/dev"
mount --make-rslave "$target/dev"
mount -t proc proc "$target/proc"
mount --rbind /sys "$target/sys"
mount --make-rslave "$target/sys"
mount --rbind /run "$target/run"
mount --make-rslave "$target/run"

# Give apt working DNS inside the chroot. NetworkManager will recreate its
# normal resolv.conf link after the HDD boots in the target machine.
if [[ -L $target/etc/resolv.conf ]]; then
    resolv_link=$(readlink "$target/etc/resolv.conf")
    rm "$target/etc/resolv.conf"
    cp -L /etc/resolv.conf "$target/etc/resolv.conf"
    resolv_changed=1
else
    resolv_regular_backup="$backup_dir/resolv.conf.before"
    cp -a "$target/etc/resolv.conf" "$resolv_regular_backup" 2>/dev/null || true
    cp -L /etc/resolv.conf "$target/etc/resolv.conf"
    resolv_changed=1
fi

echo "Installing the headless and boot packages in the existing Mint system..."
chroot "$target" /bin/sh -c '
    mkdir -p /var/lib/apt/lists/partial /var/cache/apt/archives/partial
    chown _apt:root /var/lib/apt/lists/partial /var/cache/apt/archives/partial
    chmod 0700 /var/lib/apt/lists/partial /var/cache/apt/archives/partial
'
chroot "$target" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get update
chroot "$target" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    openssh-server sudo network-manager avahi-daemon \
    grub2-common grub-pc-bin grub-efi-amd64-bin grub-efi-amd64-signed shim-signed

restore_resolv

if ! chroot "$target" id "$login_user" >/dev/null 2>&1; then
    chroot "$target" useradd --create-home --shell /bin/bash --groups sudo "$login_user"
fi

# Give the account an unknown random password so it is not considered locked;
# all password authentication is disabled below, and sudo is key-session only.
random_password=$(openssl rand -hex 32)
printf '%s:%s\n' "$login_user" "$random_password" | chroot "$target" chpasswd
unset random_password

install -d -m 0700 "$target/home/$login_user/.ssh"
install -m 0600 "$public_key" "$target/home/$login_user/.ssh/authorized_keys"
chroot "$target" chown -R "$login_user:$login_user" "/home/$login_user/.ssh"

install -d -m 0755 "$target/etc/ssh/sshd_config.d"
cat >"$target/etc/ssh/sshd_config.d/90-headless.conf" <<EOF
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AllowUsers $login_user
EOF

cat >"$target/etc/sudoers.d/90-headless" <<EOF
$login_user ALL=(ALL:ALL) NOPASSWD: ALL
EOF
chmod 0440 "$target/etc/sudoers.d/90-headless"

printf '%s\n' "$hostname" >"$target/etc/hostname"
if grep -q '^127\.0\.1\.1[[:space:]]' "$target/etc/hosts"; then
    sed -i "s/^127\\.0\\.1\\.1.*/127.0.1.1 $hostname/" "$target/etc/hosts"
else
    printf '127.0.1.1 %s\n' "$hostname" >>"$target/etc/hosts"
fi

install -d -m 0700 "$target/etc/NetworkManager/system-connections"
cat >"$target/etc/NetworkManager/system-connections/headless-wired.nmconnection" <<'EOF'
[connection]
id=Headless wired DHCP
uuid=7963ea20-1e98-4dc4-bca7-04e1e958fc4c
type=ethernet
autoconnect=true
autoconnect-priority=100

[ethernet]

[ipv4]
method=auto

[ipv6]
addr-gen-mode=default
method=auto

[proxy]
EOF
chmod 0600 "$target/etc/NetworkManager/system-connections/headless-wired.nmconnection"

install -d -m 0755 "$target/etc/systemd/logind.conf.d"
cat >"$target/etc/systemd/logind.conf.d/90-headless.conf" <<'EOF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
EOF

chroot "$target" ssh-keygen -A
install -d -m 0755 "$target/run/sshd"
chroot "$target" sshd -t
systemctl --root="$target" enable NetworkManager.service ssh.service avahi-daemon.service
systemctl --root="$target" set-default multi-user.target
systemctl --root="$target" mask sleep.target suspend.target hibernate.target hybrid-sleep.target

if grep -q '^GRUB_TIMEOUT=' "$target/etc/default/grub"; then
    sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=1/' "$target/etc/default/grub"
else
    printf 'GRUB_TIMEOUT=1\n' >>"$target/etc/default/grub"
fi
if grep -q '^GRUB_DISABLE_OS_PROBER=' "$target/etc/default/grub"; then
    sed -i 's/^GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=true/' "$target/etc/default/grub"
else
    printf 'GRUB_DISABLE_OS_PROBER=true\n' >>"$target/etc/default/grub"
fi

echo "Installing boot support for both legacy BIOS and UEFI..."
chroot "$target" grub-install --target=i386-pc --recheck "$device"
chroot "$target" grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot/efi \
    --bootloader-id=ubuntu \
    --no-nvram \
    --recheck
chroot "$target" update-initramfs -u -k all
chroot "$target" update-grub

# Make a removable-media fallback path so the target machine does not need an EFI
# NVRAM entry created on this computer.
install -d -m 0755 "$target/boot/efi/EFI/BOOT"
if [[ -f $target/boot/efi/EFI/ubuntu/shimx64.efi ]]; then
    cp -f "$target/boot/efi/EFI/ubuntu/shimx64.efi" \
        "$target/boot/efi/EFI/BOOT/BOOTX64.EFI"
    cp -f "$target/boot/efi/EFI/ubuntu/grubx64.efi" \
        "$target/boot/efi/EFI/BOOT/grubx64.efi"
    if [[ -f $target/boot/efi/EFI/ubuntu/mmx64.efi ]]; then
        cp -f "$target/boot/efi/EFI/ubuntu/mmx64.efi" \
            "$target/boot/efi/EFI/BOOT/mmx64.efi"
    fi
else
    cp -f "$target/boot/efi/EFI/ubuntu/grubx64.efi" \
        "$target/boot/efi/EFI/BOOT/BOOTX64.EFI"
fi

sync

echo
echo "Preparation completed successfully."
echo "Hostname: $hostname"
echo "SSH user: $login_user"
echo "Authorized key: $actual_fingerprint"
echo "Networking: wired DHCP through NetworkManager"
echo "Boot: legacy BIOS GRUB + UEFI fallback path"
echo "Desktop boot: disabled (multi-user target)"
echo "Lid-triggered suspend: disabled"
echo "Backups: $backup_dir"
echo
echo "After installing the HDD in the target machine, connect Ethernet and run:"
echo "  ssh -i $public_key $login_user@$hostname.local"
