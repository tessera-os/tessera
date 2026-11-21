# DeviceKit

Tessera's driver interface, below LibTessera's services and Ember. Apps never
link it. The specification is `roadmap/17-devicekit.md` in the tessera
repository.

The native Swift package under `tarwin/` tracks ownership of an already
isolated DMA grant. Adopt the kernel-issued handle and IOVA once, use one
serial executor, and call `prepareForDevice` before publishing descriptors.
The scatter helper checks access direction, subrange, alignment, hardware
segment size, boundary and descriptor budget before publishing any of them.
Only complete the grant back to the CPU after the device has stopped using
it. Failed retirement can be retried but never returns the grant to service.
Mapping, cache maintenance and synchronous IOMMU drain are platform
operations, not effects simulated by the Swift wrapper.
