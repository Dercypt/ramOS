# Governance Harness

This pipeline validates the core architectural constraints of ramOS.

## Components

1. **`verify.sh`**: The main entry point for the verification pipeline. It orchestrates formatting, building, and invariant testing.
2. **`tests/laws/`**: Contains scripts that statically and dynamically analyze the codebase to ensure `LAWS.md` invariants are preserved.

## Pipeline Steps
1. **Formatting:** `zig fmt --check .` ensures consistent code style.
2. **Safety Check:** Compiles the kernel using `zig build -Doptimize=ReleaseSafe` to ensure all software-enforced memory safety checks are active.
3. **Law Verification:** Runs all scripts in `tests/laws/` to enforce architectural invariants (e.g., checking for prohibited disk drivers or page table manipulation).
