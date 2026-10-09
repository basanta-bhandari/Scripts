#!/bin/bash
set -e
echo "[run.sh] Building ISO..."

if [ ! -f zig-out/bedrock.elf ]; then
    echo "ERROR: bedrock.elf not found"
    exit 1
fi

rm -rf iso_root
mkdir -p iso_root/boot/limine
cp zig-out/bedrock.elf iso_root/bedrock.elf
cp limine/limine.conf iso_root/limine.conf

if [ -f limine/limine-bios-cd.bin ]; then
    cp limine/limine-bios-cd.bin iso_root/boot/limine/limine-bios-cd.bin
fi

xorriso -as mkisofs \
    -b boot/limine/limine-bios-cd.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -V "BEDROCK" -o bedrock.iso iso_root/

echo "[run.sh] Launching QEMU..."
qemu-system-x86_64 -cdrom bedrock.iso -m 512M -serial stdio -no-reboot
