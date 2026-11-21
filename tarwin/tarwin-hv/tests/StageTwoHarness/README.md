# Guest-entry and second-level translation diagnostics (§23.2–3)

From this directory on the Mac:

```sh
for arch in arm rv64 x64; do sh run.sh "$arch" || exit; done
```

Requires the Swift.org 6.3.3 toolchain (set `SWIFT_TOOLCHAIN` to its bin
directory), and Homebrew QEMU on PATH. Each invocation builds the package
with Embedded Swift's no-allocation check, links a private one-vCPU ELF,
boots it using TCG and checks an exact host-only UART marker with a timeout.

| Target | Entry and exit | Translation |
| --- | --- | --- |
| aarch64 | VHE EL2 → EL1h, HVC | L2/L3 stage 2 with 16 KiB leaves |
| rv64 | OpenSBI HS → VS, ECALL | Sv48x4 with 4 KiB leaves |
| x64 | 64-bit SVM host → long-mode guest, VMMCALL | Four-level NPT and guest paging |

The guest's code and data GPAs differ from the backing PAs. A pass requires
a guest write reaching its data frame, a hypercall, a rejected write after
read-only remap, a rejected load after unmap and a rejected instruction fetch
after a nonexecutable remap. Each monitor checks architectural exit causes,
the fault address and the intact value after a denied write. Arm also tests
scalar MMIO fault decoding and load completion. The results are functional
TCG executions, not timing measurements. SVM retains every pin for the whole
test: TLB_CONTROL on VMRUN is not a synchronous unpin acknowledgement.

On Arm, RV64, AMD SVM and Intel VMX, the stopped-vCPU register check saves
the integer set, replaces every writable register (including the guest stack
pointer), runs a guest addition and checks every returned register before
restoring the original set. RV x0 must remain zero. Arm transfers X0–X30
and SP_EL1, RV transfers X0–X31, and x64 uses the architectural integer
register order. PC, flags, privilege controls, exception and vector state
are not part of this set. The test calls the kernel component with private
buffers, not through a user-mode syscall; it does not establish a complete
context switch, migration, physical execution or multicore exclusion.

The separate `TarwinHVCalls` provider implements the private §23.3 four-word
register ABI. Run `swift test --package-path tarwin-hv` from the Tarwin root
for dispatcher tests with a real handle table and a test user mapping.
They check guest layout independently of caller ISA, rights, a page boundary,
closure of an in-flight handle, and a run starting during the buffer pin.
`sh conformance/check-embedded.sh` compiles a concrete dispatcher and
provider for all three targets with allocations disabled. A live syscall
still requires a caller read epoch, whole-range pin and the vCPU run lock
from the kernel composition layer; these are not supplied by the emulator
register checks. This is not a public LibTessera SDK binding.

**Boundary:** each image has a dedicated core, one ASID/VMID, private linker
frames and a trusted instruction fixture. These are not kernel-profile builds,
physical hardware, Linux/Android/Tarwin guest boots, or §34 suite results.
Intel VMX has a separate build target: `VMX_IMAGE=/tmp/vmx.elf sh run.sh vmx-build`.
The PVH ELF contains a CPUID/feature-control gate, VMXON, VMCLEAR/VMPTRLD,
checked control/state writes, VMLAUNCH/VMRESUME, VMCALL and EPT-violation
handling, single-context INVEPT and VMXOFF. Hosted tests exercise control
admission and failure transitions. Run `sh ../VMXStageTwoProbe/bochs.sh` with
Bochs 3.1 (VMX level 2, Skylake-X model, headless display). The BIOS reads
the ELF's flat load image from the boot floppy; the monitor prints
`TARWIN X64 EPT PASS` only after VMCALL, EPT write/read/fetch violations,
INVEPT, VMCLEAR and VMXOFF succeed. This executed in Bochs, **not on
physical Intel hardware**. QEMU TCG does not expose VMX. Do not deploy it as a host.
Do not wire the diagnostic context switches into the production run path:
it needs platform pinning/VMIDs, complete per-thread register state, interrupt
and timer routing, synchronized kicks, all-CPU invalidation and verified KLF
architecture variants before running untrusted guests.

### Guest-profile debug kernel

The protection diagnostics also trap WFI with no pending interrupt and a delegated
read of ID_AA64PFR0_EL1 or satp, resume the guest with the supplied value, and check it
at the next hypercall. RV64 handles compressed MMIO stores/loads and sign extension;
when htinst is zero it fetches text only from an immutable Bare-mode guest mapping.
Unknown register selectors and side-effecting RV CSR operations are not delegated.

Run `sh run.sh arm irq` and `sh run.sh rv64 irq` for interrupt delivery. Arm uses
a software-backed GIC list register: an SPI is pending while masked, then acknowledged
and EOI'ed by EL1. The monitor verifies the virtual comparator has expired before
forwarding timer PPI 27. RV64 uses QEMU virt AIA with an IMSIC VS file: the guest
claims its message, arms vstimecmp, receives the delegated timer interrupt and disarms
it. Both guests observe their virtual counter offset. These single-vCPU diagnostics
run neither a production IRQ route nor a physical interrupt or timing acceptance case.

The Arm and RV64 monitors also re-arm a RAM write trap across two dirty-log epochs,
retry the original store after setting the bit and verify the changed backing and
bitmap. Only one CPU can walk the diagnostic root, and there are no DMA writers.

#### Separately linked console workload

Run `sh run.sh arm kernel`, `sh run.sh rv64 kernel` and `sh run.sh x64 kernel`.
Each invocation links an independent, allocation-disabled [kernel](../DebugGuest/Kernel.swift)
at GPA 0x10000. Its only segment is RX; the monitor supplies a private RW/NX
stack, a read-only descriptor at 0x180000, a framebuffer at 0x200000 and a
64-page reservation at 0x400000. Entry is EL1h (x0), VS (a0=hart, a1=descriptor)
or SVM long mode (RDI). QEMU enters the linked kernel, not the monitor's
instruction fixture. The guest renders with TarwinBoot.DebugConsole, tests
TarwinMM allocation/write/read/free, runs TarwinBootstrap.BootCPU dispatch
and sleep, and writes a bounded serial mirror. The monitor checks the exit,
guest result, pixels and mirror bounds before forwarding bytes. The runner
requires the exact three guest lines followed by the host completion marker.
Set `GUEST_ELF_DIR` to save the ELFs; `CAPTURE_DIR` saves UART captures.

This is a test-only guest profile: no tarboot, TBIB, authenticated boot set,
vTPM, signed init, virtual timer interrupt or production scheduling. A
bare-metal EL2/VHE W1 image cannot be entered at EL1h by changing its PC.
Signed W1 guest integration needs the platform owner's guest entry, segment
and admission contracts. No §34 guest OS result or W8 exit is implied.

The optional Metal profile uses the same kernel components and the device owner's
Embedded encoder. Run `sh conformance/check-metal-guest.sh` from the Tarwin root on
a Metal-capable Mac. A fixed mailbox, not a guest pointer or device register, carries
two commands and four receipts across hypercalls. The monitor forwards them over a
private serial socket to TVMM. Mosaic copies the completed frame to an independent
offscreen backbuffer and emits its release receipt after that GPU copy. Both textures
are read back and checked; this involves no display latch, physical scanout or production transport.

The optional `storage` profile maps 16 KiB of guest-private, RW/NX workspace at
0x540000. Only its first 8 KiB are the block grant. The single-vCPU monitor snapshots
the 128-byte request and 16-byte vector into its own scratch; it never follows an address
from the guest. Valid reads cover eight sectors in the 1 MiB read-only fixture. The guest
pins the known metadata head, resolves `system-version`, authenticates its file page,
and compares every byte. Run `sh conformance/check-storage-guest.sh` at the Tarwin root
for intact and corrupted payloads on each ISA. This is virtual-disk evidence only.
