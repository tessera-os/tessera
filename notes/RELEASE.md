# 26.11.1

**Project:** NotesApp  
**Release week:** 2026-11-02 – 2026-11-08

## Highlights

- Notes now consumes an explicitly transferred `StartupTag.document` File
  capability when launched through Open With. Normal launches still use its
  private Notes library. The external document path has a bounded UTF-8
  loader, a read-only view for read grants, and a multiline editor for
  explicit read/write grants. Save uses the granted handle, never a pathname,
  and preserves edited text in memory if saving fails.
- The fixed Inlay → PID 1 → Notes path now delivers the selected File in the
  confined process's `StartupTag.document` handle; the child strips Transfer
  rights before the editor uses it.
- In-place save is not yet atomic Save As. The explicit Notes route compiles,
  but the interaction has not been boot-tested and the generic document picker
  is not yet integrated.
- The external editor snapshots File identity, size and modification time on
  load and rechecks before Save. It refuses stale writes, retains unsaved text
  after a conflict, and refreshes its snapshot after a successful Save. This
  guards accidental overwrites but does not replace file locking or atomic
  Save As, and does not close a concurrent-write race during the actual write.

## Validation

- `kira check --target aarch64-unknown-tessera tessera-packages/notes` returned
  `Check: Ok` with the local Tessera cross sysroot.
- Host linking prevents the guarded boot build from reaching the guest.
