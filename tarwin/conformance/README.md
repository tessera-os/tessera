# Tarwin 26.11.1 acceptance

This is a host-side Swift lab controller and evidence checker. It does not emulate a kernel, benchmark a Mac as if it were a reference machine, or turn unit tests into acceptance evidence.

`sh conformance/check-guest-entry.sh` separately runs the [three-ISA QEMU protection and debug-guest boots, Arm/RV IRQ and timer checks, and Bochs VMX/EPT](../tarwin-hv/tests/StageTwoHarness/README.md). It does not invoke the lab adapter or emit acceptance receipts.

```sh
swift test --package-path conformance
swift run --package-path conformance tarwin-conformance refs.tsv /absolute/new-run /absolute/trusted-lab-adapter
swift run --package-path conformance tarwin-conformance refs.tsv /absolute/archived-run
swift run --package-path conformance tarwin-conformance --qemu dev.tsv /absolute/new-qemu-run /absolute/trusted-qemu-adapter
swift run --package-path conformance tarwin-conformance --train refs.tsv /absolute/archived-run dev.tsv /absolute/qemu-run
```

Use the train owner's inventory of **all** reference devices. Each non-comment row begins with eight tab-separated fields: `physical arch serial tarwin-build linux-build battery nested confidential`. Architectures: aarch64, x64, rv64. Append a ninth field, `vmx` or `svm`, for x64 only; an old x64 row with no identified backend cannot pass. Flags: yes/no from hardware discovery. Build identifiers name unique immutable builds; the Linux identifier must be the latest stable mainline configured per workload, not a distro version. The same serial must denote the same physical machine across reboots. Bind these identifiers to measured boot logs, approved reference inventory, compiler/options, workload versions and board configuration in the archived capture. The runner cannot authenticate a lab operator's claims.

In collection mode the output directory must not already exist. The runner starts the supplied executable once per reference **without a shell**, with argv: arch, serial, Tarwin build, Linux build, output root, plan path. The plan contains every required (key, system, trial) triple, tab-separated, including ten independent samples for each comparator. The lab adapter owns machine reservation, boot, timeouts, workload execution, isolation of captures from guests and pinning the same compiler/options (including SPEC), corpus, units, configuration, and device serial. It must derive result bindings from its target, not echo requests. The controller records the entire inventory and a fresh collection ID. After a clean adapter exit, it seals SHA-256 hashes of every planned result and raw capture in a receipt tied to that ID. It rechecks the inventory, every receipt and every captured byte before scoring. Dropping a reference, mixing runs, changing a log or value, or replaying pre-v2 archives is not verified. Keep the complete directory read-only during scoring. These unkeyed receipts detect accidental changes; an operator able to replace the archive can also replace the receipts. Preserve it in trusted immutable lab storage. Hashing uses the host's standard `shasum` on macOS or `sha256sum` on Linux, with no shell. Never supply a fixture or guest-controlled controller.

For each triple it writes `<root>/<serial>/<key>/<system>-<trial>.log` (original nonempty capture) and the sibling `.tsv` (one line, tabs):
```
26.11.1  physical  arch  serial  key  system  build  trial  value
```
For a suite case, value is pass/fail and trial is 1; pass means every assertion for that case executed on-target. Benchmark values must be positive, finite, unrounded and in consistent units: latency (microseconds, except probe nanoseconds), throughput/rate (operations, bytes, packets or builds per unit time), power (watts). For guest CPU-bound use equal work per time; for build benchmarks use builds per time, not elapsed time. For interactive/deadline use the measured percentile under load per trial. For power cycles the controller must capture at least 10,000 successful cycles per reference. Persist configuration and raw logs per comparator. Bare-metal CPU-bound comparison uses the nonvirtualized workload on the reference hardware (Linux build). Nested/confidential refusal gets tested even when the hardware lacks support.

The checker compares per-workload geometric means, not an average across devices or workloads. The metadata comparator is the better of separately measured ext4 and btrfs for **each** operation. Missing data, unsupported ISAs, a different serial/build, a failed case, or any missed gate blocks the train. Exit: 0 = catalogued gates passed, 1 = blocked, 2 = invocation/inventory error. A green report still requires review of captures and the coverage ledger; it is not a certificate of full spec conformance.

### Development milestones versus physical evidence

On a Mac, run `sh conformance/check-storage-guest.sh` with TRFS's GuestIO value-type
transport present. Each ISA boots an independently linked debug guest twice against a
monitor-owned, read-only virtual disk: the intact file page must verify, and changing
one payload byte without changing the pinned metadata must be rejected. The runner
requires the exact guest verdict in addition to console completion. Set `CAPTURE_DIR`
to retain both UART logs for each ISA. These plaintext fixture runs are neither block
controller tests nor signed boot, encrypted storage, physical I/O or W5 acceptance.

On a Metal-capable Mac, `swift run --package-path conformance/metal-integration metal-present-check`
checks the guest presentation encoder, TVMM and MosaicMetal against actual offscreen pixels.
The package normally uses the device owner's `drivers/tvgpu`; set `TVGPU_PACKAGE` to an
absolute peer checkout when testing an offline stack. Missing Metal is a nonzero exit, not a pass.

Run `sh conformance/check-metal-guest.sh` to link the Embedded guest-driver encoder into
the separate Arm, x64 and RV64 debug kernels. Each boots, submits both operations through a
fixed mailbox and private monitor serial relay, consumes the two receipts separately and
returns to its own kernel. After the render receipt, Mosaic pins the guest frame during its
copy to a separate offscreen backbuffer. The release receipt comes from that copy's completion;
the Mac verifies every pixel of both textures. Requires the compositor from I/O v5 (main 3628).
The relay supplies a test clock sample and a prebound grant; it does not establish production
transport, a display latch, a host picker, signed W1 boot or W4/W11 acceptance.

For W0/W1 use a separate inventory with four tab-separated fields: `qemu aarch64 site tarwin-build`.
The adapter ABI is unchanged (the Linux build argument is empty); archive result rows use
`qemu` rather than `physical`. Collect tarboot-to-self-test, SMP with signed init, and actual
object and IPC suite logs. No HV fixture, debug-console screenshot or host unit test qualifies.
Use immutable build **set** IDs that identify all signed platform/profile images; capture the
exact artifact hash for each target. Combined scoring requires matching Arm build sets in both
inventories, verifies both collections independently, and accepts neither archive in place of the other.

The physical adapter records the observed `platform.form-factor` (desktop, laptop, development-board,
server, phone, tablet, console or other), with the approved machine identity in the capture.
W10 needs at least one x64 desktop and one Arm laptop or development board; a battery flag is not proof.
The Metal presentation cases require actual per-client grants, clear/blit, two ordered completions,
bounded failure recovery and Mosaic presentation against a WorkInterval deadline. Matching wire
vectors alone do not prove any of those cases on a reference device.

## Missing evidence and traceability

`swift run --package-path conformance tarwin-conformance --unverified` emits
a TSV backlog (status, ISA, serial or "-", key) and exits **1**. It reads no
lab devices and produces no receipts. Without an inventory it includes
both conditional branches (e.g. test nested execution **or** test refusal)
and battery metrics pending discovery. Scoring an incomplete archive also
names each affected case and budget, not just the missing device. Sealed
runs predating an expanded plan cannot pass using the old receipt.
Use `--qemu --unverified` for the development milestones alone, or
`--train --unverified` for both ledgers. QEMU rows are labeled `qemu-aarch64`,
not counted as physical Arm evidence.

| Spec | What each capture must show |
| --- | --- |
| §§1–4, 33, 36.1, 38 | Link map and signed service boundary; measured firmware and CPU admission; no ambient authority or fallback. Check train ABI, Driver API and TBIB windows, layers and changelog. For each TW decision cite the linked implementation and evidence for this build; a copy of the decision text is not proof. Bind canonical TRFS, Metal and MosaicDisplay contracts; missing upstream inputs block acceptance. |
| §§23–24 | Execute mapped guest RAM and failed access after revocation on the selected architecture, including remote CPUs; verify register state, exits, timer and interrupt routing. Check admission/refusal against discovered optional features, assigned DMA/IRQ isolation, actual guest boots, firmware and vTPM; exercise each host service with valid and revoked grants. An instruction fixture or debug console boot cannot satisfy any guest OS or production service gate. |
| §§27–28 | Exercise each hook and permitted effect with an authenticated native probe, rejected authorization, map bounds, measured overhead, trace clock and counter ownership. Recover a panic record across warm reset, capture a debug dump, stop all CPUs, verify no release debugger. |
| §32 | For each limit independently: boundary, one beyond, policy override where specified, cleanup and no partial success. Include units and actual counts, not parsed constants. |
| §§34–35 | Independent suite results and ten-trial performance comparisons as above. Capture each diagnostic **and** its required build failure, refusal, fallback, termination, restart or panic. Build-time diagnostics are tied to the tested artifact, not triggered on a live kernel. |
| §36.2 | W0/W1 explicitly need platform QEMU boot and object/IPC evidence, not a debug guest. W2–W7 depend on the corresponding memory/loader, IPC/scheduler, device/Metal, storage/network, security and power suites. W8 requires Tessera and Linux guests; W9/W10 require ISA parity and hardware; W11 Android per-app surfaces; W12 every budget. Milestones depend on those captures and integration review, never a blanket pass flag. |
