# 26.11.1

**Project:** Inlay  
**Release week:** 2026-11-02 – 2026-11-08

## Highlights

- Inlay offers **Read in Notes** or **Edit in Notes** for selected regular
  `.txt` and `.md` files. The action opens the exact file using LibTessera's
  symlink-rejecting node lookup, checks its size, and queues a File handle for
  PID 1 rather than handing the child's process a path.
- Only explicitly selected documents up to 1 MiB are eligible. The editable
  action asks for write rights; the read-only action does not.
- Before transferring a File, Inlay compares the opened File's inode, volume,
  size and modification time to a snapshot of the selected Node. A changed
  file is refused instead of granting access based on a stale selection.
- The selected path's original Foundation device/inode are also compared to
  the opened Node. LibTessera converts statx major/minor to Linux `st_dev`
  encoding for this comparison, preventing an intervening replacement of the
  filename with another file of the same size and timestamp.
- Added an explicit, bounded filename search in Documents and mounted volumes,
  with results that can be revealed in their folder or safely previewed.
  Search is restricted to 75 results, four levels and a 10,000-entry work
  budget; it is not a global application-data search.
- Replaced the full-file text preview with the bounded `previewDocument`
  reader. Preview refuses linked or changed files, detects printable UTF-8
  and candidate image signatures, and limits image rendering to 8 MiB.
- Added Recent Documents in the sidebar, backed by an Inlay-owned, strict
  persisted cache. Only confirmed Notes launch acknowledgements create an
  entry; a missing volume stays visible, and Forget does not delete the file.
  Reopen rechecks the File grant rather than reusing a saved permission.

## Validation

- `kira check --target aarch64-unknown-tessera tessera-packages/inlay` returned
  `Check: Ok` with the local Tessera cross sysroot.
- `kira check --target aarch64-unknown-tessera tessera-packages/inlay/tests/operations_kik --test`
  returned `Check: Ok` including confirmed history persistence and scope tests.
- The guarded boot build is blocked at host linking, before a guest boot. The
  Inlay → PID 1 → Notes interaction is not yet boot-verified.
