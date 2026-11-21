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
reservation policy. The trap rewrite supplied by H2 runs before sealing;
different rewritten bytes never alias a cached right. Stable image-relative
branches to the gate stub let different load biases share the same code.

The task command transport is `HostedTaskCommandMappings`. Its exchange
closure sends the frozen H2 command and the optional capability, waiting
for its matching reply. A transport failure with unknown outcome must
invalidate the task before any address is reused. The kernel uses H1's
exception worker to call `resumeAfterFileFault` for data page-ins and fall
through to its exception policy for other exceptions. The fault reader
must be bound to one authenticated immutable TRFS version. For jetsam the
kernel feeds H1's `HostPressureLevel` to `HostedJetsam`, supplies reclamation
and terminates/records events on its authoritative process state.

The loader exposes the authenticated ELF TLS template and placement data;
the kernel supplies thread-local storage and passes the TCB address in H2's
`createThread`. H2's protocol uses the gate-page TCB path, not TPIDR_EL0.

Run `swift test --package-path hosted/TarwinLoaderHosted` from
`tarwin-loader` on an Apple silicon Mac.
