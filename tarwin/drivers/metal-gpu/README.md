# Hosted Metal GPU

`HostedMetalGPU` is the macOS DeviceKit-side executor for the existing
`TvGpuGuest` surface profile. Its caller supplies authenticated client and
compositor identities, slot epochs, retained read grants, a scheduler deadline
in host ticks, and the accounting and fence services. Do not pass through
identities or read grants supplied by the client.

The driver charges the actual IOSurface allocation before returning a grant.
The kernel implements `HostedGPUAccounting` with its job/footprint and process
handle state, preserving the supplied `GpuAllocation` through retirement.
`HostedRenderFence` advances its Metal shared event after the command buffer
completes successfully, then signals the Tarwin timeline via `HostedFenceSink`.
The sink can use `HostedRenderFence.signal` with the bound Signal handle,
`FenceObject`, and scheduler; on disconnect it must wake the kernel waiters
with device loss. The raw Metal event is not a capability handed to clients.

`pollRenders()` returns driver receipts. `collect(output:)` only returns
compositor release receipts after GPU copy completion; a returned frame owns
private output storage, not producer memory. Send it over the trusted display
transport with its output/generation/serial identity. Keep the last latched
hit map until a valid presented acknowledgement arrives, or retire it on a
mode change. The transport must discard or acknowledge each offered frame;
on a lost connection it must drain host access before discarding it. Hit-test
results still require the seat router to check live input grants.

For a CPU-rendered preview or boot console, trusted host code can use
`importSurface(_:client:compositor:epoch:surface:)` to retain a nonplanar BGRA8
IOSurface without charging a Tarwin client or exposing a guest grant. Unlock
CPU writes before calling `compose(output:generation:compositor:importedPlacements:)`.
On successful admission, do not write the source again until its entry in
`collect(output:).importedReceipts` arrives. A `.released` receipt permits reuse;
a `.failed` receipt is terminal and the import must be retired. Use
`retireSurface(_:)` to stop new copies, retrying after collection if one is
outstanding. Retiring does not wait for presentation of the private output copy.
Imports share the output's generation and presentation rules, but do not expose
guest hit targets or mix with guest placements in a single composition.

Open the host service slots via `HostedGraphicsDeviceProvider.Kind` in the
hosted kernel's `HostDeviceRegistry` (`gpu` and `display`). The binding can
register `HostedGraphicsDeviceProvider` with an opener that verifies the slot
and returns a fresh send-right reference to its service. The provider does
not allocate an unserved placeholder port.

Run `swift test` here on macOS 26 or later. The hosted tests do not imply a
booted Tarwin system, physical scanout evidence, or a latency result.
