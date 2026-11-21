# Hosted Tarwin memory

Tarwin delegates hosted memory compression to XNU. H3 does not create
compressed-page slots or use Tarwin's embedded compressor/free-slot
allocator (Cairn #4503). A dropped clean file page needs no slot: its
immutable file reservation remains and the next fault reads or reuses the
authenticated page.

Pass the `HostMemoryPressure` callback's level and the live address spaces
to `HostedJetsam.handle(_:addressSpaces:signal:reclaimed:terminate:)`.
On warning or critical pressure, the handler signals processes and
reclaims oldest first until the caller's `reclaimed` predicate reports
enough. Age means last page-in for clean read-only file mappings and time
made volatile for purgeable objects; ordinary guest loads do not trap.
Writable file mappings may be dirty and are not evicted. Empty purgeable
objects and dropped pages stop contributing to mapped footprint. Only
unresolved critical pressure can trigger jetsam, using the remaining
footprint to select the victim.

From this directory on Apple silicon, run `swift test --package-path TarwinMMHosted`
for the memory tests and `swift test --package-path Integration` for the
live Tarwind/H2 file-pager integration.
