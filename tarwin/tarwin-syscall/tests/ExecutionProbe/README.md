# Execution code in a firmware guest

On macOS, run `bash run.sh` in this directory. Optional arguments select
guests, e.g. `bash run.sh aarch64 riscv64`. The test uses:

- `EMBEDDED_SWIFTC`: the Swift.org 6.3.3 toolchain's `usr/bin/swiftc`,
  with the Embedded standard libraries, Clang and LLD in that toolchain.
- `QEMU_FIRMWARE`: the directory holding QEMU's EDK II code and variables
  images. All three system emulators must be on PATH for the default run.
- `EDK_BASETOOLS`: built EDK II BaseTools (tested with edk2-stable202408);
  RV64 uses its GenFw and linker script.

Each guest reserves two firmware pages, transfers an event and an eight-byte
message between handle tables, narrows rights through the native register
interface, closes the last reference and finishes an epoch grace period.
It also requeues an address waiter, wakes it and rejects its stale timeout.
The guest checks a descendant's footprint against the root's budget, then
marks its thread runnable, freezes and kills it, drains the
process handle table and checks its termination signal and the root's budget.
The guest also accounts a periodic work group's first interval, rejects its
stale completion and moves from the lower-energy model point to the faster
one as the next interval approaches its deadline. These are model operating
points, not changes to the guest CPU's clock.
Success requires both the EFI console marker and QMP's guest shutdown event.
No user mode, hardware trap, context switch, interrupt or signed Tarwin image
is involved. This does not boot a Tarwin kernel or measure performance.
