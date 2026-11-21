# Adreno 740 GPU provider

Regular Swift provider for the Adreno 740 in the Galaxy S23+ (chip ID
`0x43050a01`), shaped for the KMetal Adreno kernel contract in
`kios/KMetal/Sources/KMetal/Driver/Hardware/Adreno/Kernel/Tarwin/`: opaque
buffer handles, provider-chosen GPU addresses, persistent local mappings,
exact per-buffer read/write usage, one ordered ring and a timeline that
completes only when the job's fence write has landed.

**Discovery is not admission.** `AdrenoDiscovery.match` recognizes a registry
node by identity, register window and wired interrupt. It grants nothing.
`AdrenoGPUOpener.open` touches the platform only after a trusted platform
profile admits the device, proving the requester and its IOMMU domain,
narrowly scoped register and DMA grants, checked queue/command isolation, and
drain/revocation on that hardware. No such profile exists, so every device,
matching or not, is reported unavailable. Firmware (SQE), power and GMU
bring-up also belong to that profile and are not done here.

**Ring.** Each job becomes `CP_INDIRECT_BUFFER` packets followed by a
`CP_EVENT_WRITE7` `CACHE_FLUSH_TS` that writes the 32-bit timeline value to a
private memstore and raises `CP_CACHE_FLUSH_TS`. The ring is GPU-read-only;
the doorbell is `CP_RB_WPTR`, read back after writing. A ring without room
refuses the job with no state change. `RBBM_HANG_DETECT`, `CP_HW_ERROR`,
`CP_AHB_ERROR`, a disconnected interrupt, a stuck doorbell or an impossible
fence value lose the device.

**Buffers.** A buffer is a Memory object charged to the client, pinned and
installed in the GPU's domain at an address from `chooseDmaAddress`
(GPU-read-only buffers as `deviceRead`, others as `both`). Closing a handle
drops only the client's reference. Once every job naming it has retired,
`DmaRetirement` runs detach, IOTLB and ATC invalidation, write drain and pin
release in order (#4515). A failed step keeps the phase, address and charge
and is retried on the next close or completed wait; the charge is refunded
only after `.released`. Timeout and cancellation never retire anything. After
a lost device, every buffer named by an unretired job stays pinned and
charged until a trusted drain of the whole slot.

**Counter.** `readCounter` reads `CP_ALWAYS_ON_COUNTER` only when the profile
gives its frequency, and reports `.unsupported` otherwise; no host clock
stands in for it.

Register offsets, bits and PM4 encodings come from Mesa (MIT,
[MESA-LICENSE.txt](MESA-LICENSE.txt)).

## Tests

`swift test` runs against `FakeAdreno` in `tests/`, a host model that keeps a
register file, executes the ring on a doorbell write and reports its own
interrupts. The tests check the provider's logic (admission, ring encoding
and wrap, validation, retirement order, quarantine, counters). They are not
evidence about Adreno hardware, a native requester, a booted kernel or the
hosted Metal driver; no S23+ was attached.
