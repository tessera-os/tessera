# Hosted image loading

Add the package at `hosted/TarwinLoaderHosted` to the hosted kernel. The
kernel supplies the authenticated image policy to `HostedVerifiedImage.admit`
and its import, PAC, runtime, dispatch, feature, GPU and TLS bindings to
`HostedImageLoader.load`. The verifier and loader read the same copied ELF
snapshot. Authorization is required before placement or any Mach mapping.

Keep one `HostedImageCache` per running kernel and one
`HostedImageLoader` per task. The loader chooses uniformly across aligned
free placements in the task's reserved 64 GiB window. That window alone
offers at most 22 bits of 16 KiB page placement entropy; meeting a 28-bit
absolute-address requirement additionally depends on the task-host
reservation policy. Before sealing, the caller passes the admitted
`trapRVAs` for each text segment to H2's rewriter. Only listed AArch64
`svc #0` sites become eligible for syscalls; diagnostic BRK entries do
not. The rewrite receives the guest veneer address and returns `text`,
`veneers`, and `siteMap`. The loader maps the text and veneers RX in
the same transaction, then returns the absolute veneer-PC-to-original-PC
map for that process. Keep guest threads stopped until the map is enrolled.
Different rewritten bytes never alias a cached right.

For an executable with dependencies, call `loadGroup` with the admitted
images in dependency-resolver order. The resolver gets the source image
index and every image base before any mappings are installed, so it can
bind against dependencies placed by that same transaction. The caller
supplies dependency selection, RIDL matching and per-process pointer
signing. The group is returned in input order only after the batch maps.

The task command transport is `HostedTaskCommandMappings`. Its exchange
closure sends the frozen H2 command and the optional capability, waiting
for its matching reply. A transport failure with unknown outcome must
invalidate the task before any address is reused. Before spawning a task,
Tarwind can create a process-bound exception right with
`makeExceptionSendRight(process:pager:)` and pass it to H2's spawner.
The pager calls the process's `HostedAddressSpace.resumeAfterFileFault`
for data page-ins and returns nil for other exceptions. Bind the address
space after check-in and before resuming any guest thread. The fault reader
must be bound to one authenticated immutable TRFS version. For jetsam the
kernel feeds H1's `HostPressureLevel` to `HostedJetsam`, supplies reclamation
and terminates/records events on its authoritative process state.

The loader exposes the authenticated ELF TLS template and placement data;
the kernel supplies thread-local storage and passes the TCB address in H2's
`createThread`. H2's protocol uses the gate-page TCB path, not TPIDR_EL0.

Run `swift test --package-path hosted/TarwinLoaderHosted` from
`tarwin-loader` on an Apple silicon Mac.
Run `swift test --package-path hosted/integration` to test the loader with
H2's LibTessera trap rewriter. This test package is separate so that the
kernel can depend on the loader without importing LibTessera's package graph.
Run `swift test --package-path ../tarwin-mm/hosted/TarwinMMHosted` for the
hosted memory suite.
Run `swift test --package-path ../tarwin-mm/hosted/Integration` from the
same directory to check a Tarwind-mounted TRFS page-in and guest resume
through H1's exception pager and the H2 task host.

## Signed guest fixtures

Use the [native image contract](../IMAGE-WIRE.md), not Mach-O or a
`.tirpkg` SDK archive. An AArch64 app fixture needs a finalized Tarwin
`aarch64.base` ELF with the `app/executable` profile and a TSG1 signature
accepted by the kernel's installed trust policy. The grant list is signed
ELF note 3; the application identifier is supplied by launch policy, not
that note or the file name. See [Tarwin](../../../tessera/roadmap/Tarwin.md)
§§9.5, 11.2 and 25.4 for grants and the startup ABI: `_tarwin_process_start`
takes one child-local bootstrap-channel handle.

`HostedVerifiedImage.admit` delegates authorization to the caller; it
does not provide a test signer or enroll trust roots. The disposable
signer in [SIGN-FIXTURE.md](../SIGN-FIXTURE.md) supports QEMU and W1 system
fixtures, not an app-profile I/O fixture. Use a compiler/linker that emits
the native image contract and the matching guest LibTessera SDK; the
unsigned inspector described in that contract checks structure, not
authorization.
