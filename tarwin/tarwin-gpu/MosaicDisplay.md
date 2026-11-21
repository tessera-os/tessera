# MosaicDisplay 1 — Metal presentation on Tarwin

MosaicDisplay is the user-space compositor. It alone configures displays and
the seat's input routing. Tarwin §22 supplies memory attribution, revocable
doorbells, timeline fences and work intervals. DeviceKit supplies an isolated
driver slot. Metal is the graphics API; no Ember spec or runtime is required.

## Objects and ownership

A display output is a compositor-owned mode and a pool of private backbuffers.
Output configuration, z-order, focus, rotation and mode selection are not app
GPU commands. A mode change, hot unplug or compositor restart retires the old
output generation and its input map. Acquire only an unscanned backbuffer and
never overwrite one still used for scanout. Drivers without hardware support
for the required isolation must refuse the operation.

Mosaic grants one client in one authenticated GPU context access to a surface.
The grant binds the process, compositor, nonzero local surface ID, non-repeating
slot epoch, format and dimensions. IDs on the wire are local, not capabilities
or addresses. Charge system or device-local backing and aliases once against
the client job **before** admission; retain and drain mappings before refund.
A destination must be writable and a blit source must be a separately retained
readable image in that context, with disjoint backing, exact size and format.
Do not infer authority from a guessed ID, the numerical process ID in an
untrusted command, or a visible window. All grant resolution occurs under
the kernel/driver registry's lifetime rules.

A VM scanout, or each individual guest window (including Android), has a
separate surface. The compositor can place these alongside native windows; it
does not grant the VM a physical connector, a global input stream, or another
app's pixels. TVMM owns guest-agent mapping and injection. Input is routed
only with a live input grant, to the topmost hit surface in the **latched**
layout in its local pixel coordinates. Revoking a surface/output or changing
focus invalidates pending routing; keyboard input additionally requires the
seat's current focus grant. Clipboard, camera, audio and file-picker grants
are independent and not encoded by this interface.

## Metal surface profile 1

This first profile is a real, limited presentation contract, not a complete
Metal API or Apple GPU firmware ABI. Negotiate at context setup; no silent
fallback. It uses single-sample BGRA8Unorm linear 2D textures, no scaling,
1…16384 pixels on each axis, and a single outstanding frame per surface.
A clear uses a Metal render pass with load=clear and store=store; a blit copies
the complete 2D image at mip 0, slice 0. Shader delivery stays on the separate
verified module path. Unsupported formats, shader features and opcodes fail,
rather than executing user code or bypassing the TVISA verifier. A guest
binding needs no Apple SDK. A hosted provider may use the Metal SDK.

Submit only on a prebound queue, with monotonic nonzero 64-bit serials (gaps
allowed, never wrap). The trusted presentation WorkInterval supplies a
monotonic deadline and aligns scheduler donation to the driver's workers.
Reject new work for a retired epoch. Queueing or dispatch does **not** signal
the exported Fence; signal only the frame actually completed by the device.
The scheduler and coherent fence word remain Tarwin kernel services.

### Command (64 bytes, little-endian)

| Offset | Width | Field |
|---:|---:|---|
|0|4|ASCII TMS1|
|4, 6|2 each|version 1; opcode 1 clear+present or 2 blit+present|
|8, 16, 24|8 each|slot epoch, serial, surface|
|32|8|local source image for blit; zero for clear|
|40|8|nonzero work-interval deadline|
|48|4|linear BGRA8 (B in low byte), zero for blit|
|52, 56|4 each|exact grant width and height|
|60|4|reserved zero|

### Completion (32 bytes, little-endian)

ASCII TMC1 at 0; u16 version=1 at 4; u16 phase at 6; u64 epoch, serial and
surface at 8, 16 and 24. No unbound mailbox may supply a completion.

1. Phase 1 (rendered): exact successful GPU completion; ownership passes to
   the compositor, not back to the producer.
2. Phase 2 (released): compositor no longer samples the source; only after
   phase 1, and only once. A copy into private scanout storage releases its
   inputs **after** the copy GPU completes; it does not mean scanout latched.
3. Phase 3 (failed): fail the submission and quarantine retained mappings.
   A provably unsubmitted command can return without an outstanding frame;
   an indeterminate submission is never retried in place. On failure, unplug
   or restart discard outstanding tickets, notify waiters of loss and drain
   GPU, CPU and scanout access before releasing storage. Rebind with a fresh
   epoch. A stale, reordered or duplicate reply never frees another frame.

## Compositing and acceptance

The opaque baseline clears the private target to black and copies each ready
surface back-to-front, clipping in widened signed coordinates at output
boundaries. Admit the whole frame before submitting work. Do not render a
duplicate surface in one transaction, sample an unready surface or release a
sampled source early. Hit testing uses the same placements in reverse order.
The baseline omits blending, HDR, transforms, cursor planes and overlays;
do not advertise them. Future profiles require negotiated versions.

Test command and completion bytes independently across guest and TVMM, read
back actual Metal-rendered pixels, verify source grants, stale completions
and separate render/release, and compare composed pixels with input geometry.
A hosted device (even with real MTLCommandBuffer completion) is not booted
Tarwin, a physical display driver, a working interrupt-driven native Fence,
display mode setting, an authenticated seat router or a deadline measurement.
