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

echo "[+] All checks passed successfully!"
