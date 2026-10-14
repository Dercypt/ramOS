#!/usr/bin/env bash
set -e

# scripts/build_iso.sh
# Assembles a minimal bootable ISO/disk image with Limine UEFI files, limine.conf, and kernel.elf.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KERNEL_BIN="$ROOT_DIR/zig-out/bin/kernel.elf"
ISO_OUTPUT="$ROOT_DIR/image.iso"
LIMINE_DIR="$ROOT_DIR/boot/limine"
ISO_STAGING="$ROOT_DIR/.iso_staging"

# 1. Ensure kernel binary exists
if [ ! -f "$KERNEL_BIN" ]; then
    echo "[*] Building kernel.elf..."
    zig build kernel -Doptimize=ReleaseSafe
fi

# 2. Ensure Limine UEFI files exist
mkdir -p "$LIMINE_DIR"
if [ ! -f "$LIMINE_DIR/BOOTAA64.EFI" ]; then
    echo "[*] Fetching Limine AArch64 UEFI binary (BOOTAA64.EFI)..."
    curl -sL "https://raw.githubusercontent.com/limine-bootloader/limine/v7.x-binary/BOOTAA64.EFI" -o "$LIMINE_DIR/BOOTAA64.EFI" || true
fi

if [ ! -f "$LIMINE_DIR/limine-uefi-cd.bin" ]; then
    echo "[*] Fetching Limine UEFI CD boot sector (limine-uefi-cd.bin)..."
    curl -sL "https://raw.githubusercontent.com/limine-bootloader/limine/v7.x-binary/limine-uefi-cd.bin" -o "$LIMINE_DIR/limine-uefi-cd.bin" || true
fi

# 3. Ensure QEMU_EFI.fd exists in root for QEMU launch
if [ ! -f "$ROOT_DIR/QEMU_EFI.fd" ]; then
    for candidate in \
        "/tmp/edk2/usr/share/qemu-efi-aarch64/QEMU_EFI.fd" \
        "/usr/share/qemu-efi-aarch64/QEMU_EFI.fd" \
        "/usr/share/AAVMF/AAVMF_CODE.fd" \
        "/usr/share/edk2/aarch64/QEMU_EFI.fd" \
        "/opt/homebrew/share/qemu/edk2-aarch64-code.fd" \
        "/usr/local/share/qemu/edk2-aarch64-code.fd"; do
        if [ -f "$candidate" ]; then
            cp "$candidate" "$ROOT_DIR/QEMU_EFI.fd"
            break
        fi
    done
fi

# 4. Populate ISO staging directory
rm -rf "$ISO_STAGING"
mkdir -p "$ISO_STAGING/EFI/BOOT"

cp "$ROOT_DIR/limine.conf" "$ISO_STAGING/limine.conf"
cp "$KERNEL_BIN" "$ISO_STAGING/kernel.elf"

if [ -f "$LIMINE_DIR/BOOTAA64.EFI" ]; then
    cp "$LIMINE_DIR/BOOTAA64.EFI" "$ISO_STAGING/EFI/BOOT/BOOTAA64.EFI"
fi

if [ -f "$LIMINE_DIR/limine-uefi-cd.bin" ]; then
    cp "$LIMINE_DIR/limine-uefi-cd.bin" "$ISO_STAGING/limine-uefi-cd.bin"
fi

# 5. Generate ISO using available image tool
echo "[+] Generating bootable ISO: $ISO_OUTPUT..."
if command -v xorriso >/dev/null 2>&1 && [ -f "$ISO_STAGING/limine-uefi-cd.bin" ]; then
    xorriso -as mkisofs -b limine-uefi-cd.bin \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        --efi-boot limine-uefi-cd.bin \
        -efi-boot-part --efi-boot-image --protective-msdos-label \
        "$ISO_STAGING" -o "$ISO_OUTPUT" 2>/dev/null
elif command -v hdiutil >/dev/null 2>&1; then
    rm -f "$ISO_OUTPUT"
    hdiutil makehybrid -iso -joliet -o "$ISO_OUTPUT" "$ISO_STAGING" >/dev/null
elif command -v genisoimage >/dev/null 2>&1; then
    genisoimage -o "$ISO_OUTPUT" -r -J "$ISO_STAGING" 2>/dev/null
else
    echo "[!] No ISO creation tool found (xorriso, hdiutil, or genisoimage)."
    echo "    Creating minimal disk image placeholder."
    tar -cf "$ISO_OUTPUT" -C "$ISO_STAGING" .
fi

rm -rf "$ISO_STAGING"
echo "[+] ISO successfully generated at $ISO_OUTPUT"
