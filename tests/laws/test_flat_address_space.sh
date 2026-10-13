#!/usr/bin/env bash
set -e

# Invariant Test: Law of the Single Flat Space
# Tasks share a single 64-bit flat address space.
# Switching translation table base registers (TTBR0_EL1, TTBR1_EL1) or flushing TLBs (TLBI)
# during task switching is prohibited.

BANNED_AARCH64_INSTRUCTIONS=("ttbr0_el1" "ttbr1_el1" "tlbi")

for term in "${BANNED_AARCH64_INSTRUCTIONS[@]}"; do
    if grep -rni "$term" src/ 2>/dev/null; then
        echo "ERROR: Found prohibited address space manipulation '$term' in src/."
        echo "ramOS enforces a single flat address space without per-task page table switching or TLB flushes."
        exit 1
    fi
done

echo "OK: Flat address space invariant verified (no TTBR/TLBI register switching in src/)."
exit 0
