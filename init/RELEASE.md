# 26.11.1

**Project:** TesseraInit  
**Release week:** 2026-11-02 – 2026-11-08

## Highlights

- Boot, service tables, kernel-log copying, supervisor, and startup code changed in 7 tracked package file(s) since the `26.10.4` baseline.

## Changed

- Added a fixed `OpenDocument` workspace request. PID 1 accepts a second
  transferred File handle only from its already-running sealed Inlay service,
  validates the message shape and read/edit mode, and always chooses the
  system Notes executable. A successful request starts a fresh, confined Notes
  instance rather than forwarding an unscoped path or silently reusing one.
- `startWithDocument` duplicates and narrows the File grant before launch;
  refusal, startup failure and malformed requests release their handles.
- The workspace parser validates the reply as a writable Channel and the
  selected document as a readable, transferable File. Edit requests require
  an existing write right; a misleading handle cannot start Notes.
- The selected handle is also checked against its opened File metadata and
  underlying node kind. PID 1 rejects special devices, oversized files, or
  a read-only open passed as an edit grant before launching a child.
- PID 1 now writes an explicit, path-free `DocumentOpened` reply only after
  starting the new Notes process. Failed launches retain the existing error
  reply; a disconnected channel is not treated as success by Inlay.
- `app/Boot.kira`
- `app/Service/Table.kira`
- `app/Storage/KernelLogCopy.kira`
- `app/Supervise/Loop.kira`
- `app/Supervise/Output.kira`
- `app/Supervise/Platform.kira`
- `app/main.kira`

## Validation

- Changes checked against Cairn entries 47–66 (after the `26.10.4` baseline). No build, device test, or publication performed for this note.
