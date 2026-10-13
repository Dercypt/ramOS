# Agent Directives

When AI agents or subagents operate in this repository, they must adhere to the following workflow:

1. **Review Laws:** Read `LAWS.md` and `PRINCIPLES.md` before writing or modifying any code.
2. **Verify Changes:** Run `./verify.sh` after every logical block of changes.
3. **No Storage Fallbacks:** Do not attempt to introduce block device drivers for swapping.
4. **Safety First:** Utilize Zig's safety features over hardware isolation. When writing inline assembly for AArch64, strictly constrain it to low-level bootstrap routines.
