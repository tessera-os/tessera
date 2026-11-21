# DeviceKit

Tessera's driver interface, below LibTessera's services and Ember. Apps never
link it. The specification is `roadmap/17-devicekit.md` in the tessera
repository.

Run `swift test` from the DeviceKit package root for the native Swift sources
under `tarwin/`. The package acquires a slot's existing domain
with `NativeDmaDomain.acquire`. Its `map` method issues the generated
`DmaBuffer.create` selector through LibTessera and returns a CPU-owned
buffer on success. The first result is the buffer handle, the second is the
device address (which may be zero); neither is the VM pin. Close the domain
handle independently. Adopt each kernel-issued buffer only once, use one
serial executor, and call `prepareForDevice` before publishing descriptors.
The scatter helper checks access direction, subrange, alignment, hardware
segment size, boundary and descriptor budget before publishing any of them.
Only complete the grant back to the CPU after the device has stopped using
it. Failed retirement can be retried but never returns the grant to service.
Mapping, cache maintenance and synchronous IOMMU drain are platform
operations, not effects simulated by the Swift wrapper.
