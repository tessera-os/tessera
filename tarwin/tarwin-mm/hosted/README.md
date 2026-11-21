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

Providers use `copyIn(at:count:)`, `withPinned(at:count:_:)`, and
`copyOut(_:to:)` on the task's address space. These calls validate the
whole guest span and page in file-backed mappings before using H2's
live-memory transfers. `withPinned` borrows a host copy of the bytes for
the closure; it does not expose a guest pointer. Pins prevent H3
unmapping, pressure eviction, and purge during the operation. Private
writes are made in the owning task so XNU preserves copy-on-write.

Use `reserveGuard(address:size:)` for the inaccessible pages bordering a
guest stack or heap. These ranges stay reserved in H2's inaccessible
task window, count against placement but not footprint, and never page
in. `protect(address:size:protection:)` changes page-aligned private
data mappings within their original rights, including revoking all
access. It does not remap live data, elevate shared or sealed executable
mappings, or change footprint. Fork inherits guards and current rights
on readable mappings. Until H2 can snapshot live unreadable pages, fork
returns `HostedMemoryError.unreadableForkRange` if a private data mapping
contains such a page.

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
