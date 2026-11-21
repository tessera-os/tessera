# USB mass storage

Regular Swift user-space driver for a directly attached, full-speed USB Mass
Storage interface (SCSI Transparent Command Set, Bulk-Only Transport).
`UHCIStorageBus` drives a single root port on a cold PCI UHCI function.
DeviceKit must first claim the function exclusively, disable firmware legacy
ownership, grant its register window, and pin three distinct physical pages in
its isolated domain. Use a device-readable frame list and bidirectional
schedule and bounce pages. Bus mastering is enabled only after translation is
active. Do not compose this with an identity-DMA fallback.

The bus resets and enables the port, reads the device and configuration
descriptors, assigns an address and selects the first configuration and
specified interface's alternate zero. Transfers are polled, one full-speed
packet at a time. The driver checks port state, TD status and byte count, and
waits for HCHalted before reusing its descriptors. On timeout, disconnect or
controller error it stops submitting. Only the domain owner can retire pins
after stopping DMA and draining the IOMMU. A failed halt is not a drain.
Stopping before cold-controller acceptance never writes its registers; an
absent function or controller fault is not accepted as a halt acknowledgement.
Hubs, low/high/super speed controllers, UAS and multi-device enumeration are
outside this driver.

`USBDisk` probes a LUN and its geometry. It supports read/write (10 and 16),
SYNCHRONIZE CACHE, and FUA only if reported. It never retries an ambiguous
write or exposes partial read data. Media changes invalidate the cached
geometry. Bulk-Only reset recovery clears both endpoint halts and resets data
toggles; a failed recovery detaches the transport.

Writable SPC-3 or newer devices can advertise SCSI UNMAP. The driver checks
the supported VPD page list, the LBPU flag and positive descriptor and LBA
limits before advertising discard. One request emits one bounded descriptor
without rounding or replay; it does not promise that reads return zero.

`USBBlockService` accepts the existing A.4 block records on queue zero. Up to
32 pinned vectors and 1 MiB of data are allowed per request. Every vector is
validated before USB I/O; CPU mappings remain pinned for the serialized
call, and only private bounce data reaches the controller. Malformed or
old-epoch records have no completion. Unsupported operations (including
zero, zones and atomic writes) do not touch the disk. The block
scheduler owns ring publication, pin retirement and client port completion.

Run from this directory on macOS with QEMU installed:

```sh
TARWIN_QEMU_X64="$(command -v qemu-system-x86_64)" swift test
swift run -c release --package-path ../virtio/Tools/BlockQTest BlockQTest "$(command -v qemu-system-x86_64)" --usb-vtd
```

The package test checks CBW/CSW framing, stalls, media changes and bad grants,
then uses a QEMU UHCI controller and USB disk for scatter I/O through the
block rings and completion port. The separate q35 check uses translated
private pages, verifies with qemu-img that only the requested 4 KiB cluster
was deallocated in a fully allocated qcow2 image, compares the complete
virtual disk and drains the mappings.
Neither is a native DeviceKit launch, physical USB test or power-loss
durability result.
