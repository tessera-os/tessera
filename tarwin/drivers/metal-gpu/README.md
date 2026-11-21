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

Open the host service slots via `HostedGraphicsDeviceProvider.Kind` in the
hosted kernel's `HostDeviceRegistry` (`gpu` and `display`). The binding can
register `HostedGraphicsDeviceProvider` with an opener that verifies the slot
and returns a fresh send-right reference to its service. The provider does
not allocate an unserved placeholder port.

Run `swift test` here on macOS 26 or later. The hosted tests do not imply a
booted Tarwin system, physical scanout evidence, or a latency result.
