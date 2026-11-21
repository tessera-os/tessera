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

`HostedAddressSpace.fork(into:)` clones memory into a fresh checked-in
task, not a guest `fork` syscall. Keep the parent's guest threads stopped
until cloning completes; the child must have no guest mappings or
running threads. H3 snapshots live private mappings (those mapped with
`copy: true` and resident writable file pages) through H2's snapshot
command and maps them copy-on-write in the child. Shared mappings,
including sealed code, keep their original entries. File reservations
are inherited, so absent pages still fault independently. If the
transport outcome is unknown or rollback fails, discard the child task.

From this directory on Apple silicon, run `swift test --package-path TarwinMMHosted`
for the memory tests and `swift test --package-path Integration` for the
live Tarwind/H2 file-pager integration.
