# Execution code in a firmware guest

On macOS, run `bash run.sh` in this directory. Optional arguments select
guests, e.g. `bash run.sh aarch64 riscv64`. The test uses:

- `EMBEDDED_SWIFTC`: the Swift.org 6.3.3 toolchain's `usr/bin/swiftc`,
  with the Embedded standard libraries, Clang and LLD in that toolchain.
- `QEMU_FIRMWARE`: the directory holding QEMU's EDK II code and variables
  images. All three system emulators must be on PATH for the default run.
- `EDK_BASETOOLS`: built EDK II BaseTools (tested with edk2-stable202408);
  RV64 uses its GenFw and linker script.

Each guest reserves scratch pages, transfers an event and an eight-byte
message between handle tables, cancels the pending operation on that specific
sender name and waits for its provider to finish before delivery, narrows
rights through the native register interface, closes the last reference
and finishes an epoch grace period.
It also resolves a borrowed self-process handle through the native register
interface, and rejects that call after process exit. It requeues an address
waiter, wakes it and rejects its stale timeout.
The guest preloads a child's sole bootstrap channel with a §11.4 Startup
message and a job handle, verifies the child-local name, decodes the
received grant, and rejects reuse of the handoff after the read.
Peek and read use the native register ABI with private diagnostic buffers,
not EL0 pointers. After draining Startup, peek reports peer closure.
Before preload, native write sends a grant through the FIFO, invalidates
the sender name and receives the grant back under a fresh name.
Before preload, a 64-byte synchronous call and reply moves a grant both
ways between the two tables without using either channel FIFO. The local
scheduler selects the waiting worker on the caller's scheduling context
and selects the caller on reply; these are scheduler IDs, not register saves.
On AArch64 it also constructs two equally mapped, never-installed roots,
checks that only the child's root yields a frame, and compares x0 to the
preloaded local name. The descriptor test does not initialize a real TCB,
execute mapped code, authenticate an image or enter EL0.
The AArch64 guest also generates one five-pair key bank from deterministic
test input, checks IA access before start and thread access after start,
and checks that retirement wipes every word. It never installs those keys.
It checks a descendant's footprint against the root's budget, then
marks its thread runnable, freezes and thaws it, and dispatches process exit
with a negative code. Exit requests a thread stop rather than a return.
A later job kill preserves the first exit cause. It drains the
process handle table and checks its termination signal and the root's budget.
The guest also accounts a periodic work group's first interval, rejects its
stale completion and moves from the lower-energy model point to the faster
one as the next interval approaches its deadline. These are model operating
points, not changes to the guest CPU's clock.
Success requires both the EFI console marker and QMP's guest shutdown event.
The event-pair diagnostic signals the peer through the native binding, refuses
a wait-only duplicate's signal, and checks peer death only after the last close.
The guest creates the port through the native ABI, posts an untrusted user
packet and checks that the kernel supplied its kind and timestamp. It arms
an edge observer, checks the peer's Signal packet, cancels by port/key and
consumes the terminal Cancelled packet after the provider acknowledges.
It also refuses a submission under backpressure, modifies the shared record,
then commits the original private copy exactly once. This diagnostic operation
reserves its own completion; it is not a frozen submission opcode.
It publishes the packet into the shared TRNG mapping, drains it through
the native ring waiter without entering the gate, polls empty and acknowledges
consumption. This does not exercise a scheduler sleep or a live Memory mapping.
No user mode, hardware trap, context switch, interrupt or signed Tarwin image
is involved. This does not boot a Tarwin kernel or measure performance.
