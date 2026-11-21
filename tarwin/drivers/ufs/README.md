# UFS block driver

Regular Swift driver for a cold, exclusively assigned UFSHCI 4.x controller
with legacy single-doorbell support. After DME link startup, NOP and device
initialization, REPORT LUNS on the well-known reporting unit discovers
standard LUs. Only complete, unique peripheral addresses consistent with the
device descriptor's LU count reach the selection callback. The driver stops
the idle controller if selection is declined or unlisted. It checks the
selected unit descriptor against SCSI
READ CAPACITY(16). It rejects a disabled or empty LU, protection information,
disagreeing capacities and block sizes outside 512–4096 bytes.

One polled hardware slot serves one A.4 queue. READ/WRITE(10) or (16) is chosen
by LBA and length. MODE SENSE(10) determines FUA support and augments the unit's
write protection. FUA sets the SCSI write command's FUA bit; flush uses
SYNCHRONIZE CACHE(10) with IMMED clear. Discard, write-zeroes, zoned and atomic
commands are not advertised. Up to 32 nonoverlapping, dword-aligned segments
of up to 256 KiB fit in the private PRD table. Epoch, range, directional grants
and exact byte count are checked before ringing the doorbell. A residual
transfer cannot produce a successful block completion.

The caller supplies two distinct, pinned 4 KiB DMA pages and the mapped BAR.
It must serialize calls, prevent physical aliases of the private pages and
hold every grant until completion or a positive controller reset and domain
drain. A normal discovery or command rejection stops the idle controller before
returning. If ownership is uncertain (malformed reply, fault, timeout or failed
stop), startup throws `UFSStartupQuarantine`: retain the controller and its
grants for platform recovery, not immediate reuse.
A malformed reply, device failure or timeout does not release active grants.
Stop is refused until the pending block completion has been polled.
MCQ, inline crypto, native driver launch, interrupt delivery, PHY power
management and recovery after a fatal fault are not implemented here.

Run `swift test` here. The QEMU check runs on macOS:

```sh
swift run -c release --package-path ../virtio/Tools/BlockQTest BlockQTest "$(command -v qemu-system-x86_64)" --ufs
```

The host-side driver discovers two LUs on q35, selects one and checks its geometry. The fixture
tests ordinary and FUA writes through three DMA segments, flush, readback,
guard bytes and four client port completions. After shutdown it compares the
entire backing file and the untouched second disk. This does not boot Tarwin, perform IOMMU translation,
simulate power loss or test a physical flash controller.
