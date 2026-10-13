#!/usr/bin/env bash
set -e

# This invariant test ensures we haven't introduced any block device or disk drivers.
# As per the Law of Absolute RAM Residency, ramOS does not page to disk.

BANNED_TERMS=("virtio-blk" "nvme" "sata" "ide" "swap" "pagefile")

for term in "${BANNED_TERMS[@]}"; do
    if grep -rni "$term" src/ 2>/dev/null; then
        echo "ERROR: Found banned disk/storage term '$term' in the source tree."
        echo "ramOS strictly forbids secondary storage drivers for memory paging."
        exit 1
    fi
done

echo "OK: No disk driver code detected."
exit 0
