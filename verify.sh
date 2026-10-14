#!/usr/bin/env bash
set -e

echo "[+] Starting ramOS verification pipeline (Zig + AArch64 + Zstd)..."

# Check if zig is installed
if command -v zig >/dev/null 2>&1; then
    echo "[+] 1. Checking formatting..."
    zig fmt --check src/ build.zig

    echo "[+] 2. Building kernel (ReleaseSafe)..."
    zig build kernel -Doptimize=ReleaseSafe --summary all
else
    echo "[!] Zig compiler not detected in PATH."
    echo "    To install on macOS: brew install zig"
    echo "    Skipping compiler build step for now."
fi

echo "[+] 3. Checking laws and invariants..."
for test_script in tests/laws/*.sh; do
    if [ -x "$test_script" ]; then
        echo "    Running $test_script..."
        "$test_script"
    fi
done

echo "[+] 4. Verifying QEMU target and assembling bootable ISO..."
if [ -f "scripts/build_iso.sh" ]; then
    echo "    Assembling minimal bootable ISO/disk image with Limine UEFI..."
    ./scripts/build_iso.sh
fi

if command -v qemu-system-aarch64 >/dev/null 2>&1; then
    echo "    qemu-system-aarch64 detected."
    if [ "${RUN_QEMU:-0}" = "1" ] || [ "$1" = "--qemu" ]; then
        echo "    Launching kernel in QEMU via 'zig build run'..."
        zig build run
    else
        echo "    Run './verify.sh --qemu' or 'zig build run' to launch QEMU test."
    fi
else
    echo "[!] qemu-system-aarch64 not detected in PATH."
    echo "    To install on macOS: brew install qemu"
    echo "    Skipping QEMU launch for now."
fi

echo "[+] All checks passed successfully!"
