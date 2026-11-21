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
