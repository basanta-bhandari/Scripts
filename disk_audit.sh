#!/bin/bash
# Disk audit script - run with sudo from a live USB or your current system
# Gathers everything needed to plan a 500GB Omarchy/Arch install safely

echo "======================================"
echo "  DISK AUDIT REPORT"
echo "======================================"

echo -e "\n--- 1. Block devices & partitions (lsblk) ---"
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT,PARTLABEL

echo -e "\n--- 2. Disk identification (by-id, useful for NVMe vs SATA) ---"
ls -la /dev/disk/by-id/ 2>/dev/null | grep -v part

echo -e "\n--- 3. Partition tables per disk (fdisk -l) ---"
for disk in $(lsblk -d -n -o NAME | grep -Ev "loop|sr"); do
    echo "=== /dev/$disk ==="
    fdisk -l /dev/$disk 2>/dev/null
    echo ""
done

echo -e "\n--- 4. Free/unallocated space check (parted) ---"
for disk in $(lsblk -d -n -o NAME | grep -Ev "loop|sr"); do
    echo "=== /dev/$disk ==="
    parted /dev/$disk --script print free 2>/dev/null
    echo ""
done

echo -e "\n--- 5. Filesystem usage on mounted partitions (df -h) ---"
df -h -x tmpfs -x devtmpfs

echo -e "\n--- 6. Boot mode (UEFI vs BIOS) ---"
if [ -d /sys/firmware/efi ]; then
    echo "System is booted in UEFI mode"
else
    echo "System is booted in BIOS/Legacy mode"
fi

echo -e "\n--- 7. Current OS(es) detected (os-prober, if installed) ---"
if command -v os-prober >/dev/null 2>&1; then
    os-prober
else
    echo "os-prober not installed (optional - skip if not needed)"
fi

echo -e "\n======================================"
echo "  END OF REPORT - paste this back"
echo "======================================"
