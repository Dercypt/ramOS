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

# Invariant Test: Phase 5 Single Flat Space Task Switcher
if [ ! -f "src/task.zig" ]; then
    echo "ERROR: src/task.zig missing. Phase 5 green thread task switcher must be implemented."
    exit 1
fi

if ! grep -Eq "pub const TaskContext = extern struct" src/task.zig; then
    echo "ERROR: TaskContext must be declared as 'extern struct' in src/task.zig to guarantee predictable C-ABI layout for inline assembly context switching."
    exit 1
fi

if ! grep -q "Scheduler" src/task.zig; then
    echo "ERROR: Scheduler must be defined in src/task.zig."
    exit 1
fi

if ! grep -q "switchContext" src/task.zig; then
    echo "ERROR: switchContext must be implemented for cooperative green threads in src/task.zig."
    exit 1
fi

if ! grep -q "taskEntryTrampoline" src/task.zig; then
    echo "ERROR: taskEntryTrampoline must be implemented in src/task.zig."
    exit 1
fi

if command -v zig >/dev/null 2>&1; then
    zig test src/task.zig
fi

echo "OK: Flat address space and task switcher invariants verified in src/task.zig."
exit 0
