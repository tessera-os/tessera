# 19 — Files and documents

Keep documents, organise them in Inlay, and open them in the application the
person chooses. This chapter extends [05](05-storage-and-state.md)'s storage
and [12](12-apps.md)'s application model.

## Starting point

Inlay currently lists application images and installed applications, with
install and eject actions. The Volume service discovers and mounts removable
volumes. Notes saves its own page in its application data directory. These
exist; the checkpoints below describe the document workflows to add.

## Decisions

Recorded before the Trash service is built.

- Trash is one folder on the data volume, `data/Trash`, with `items/` and
  `records/` beneath it. The data volume is the only one that holds Trash in
  the first slice. Items on other writable volumes get the explicit
  permanent-delete action until a per-volume Trash is built.
- Moving to Trash is a rename into `items/`, which is atomic on the one volume.
  The record (the original path, as text, under `records/` with the item's
  name) is written first. A record without an item is removed when the
  service starts. An item without a record is kept, and is listed as having
  no known origin.
- Put Back renames the item to its recorded path. When something already
  exists there, the service answers `Collision` and changes nothing. Replacing
  or keeping both is the caller's choice.
- The service is `tessera.trash`, a system service with a broker entry. It is
  the only writer of `data/Trash`, so Inlay and Settings ask it to act.
- Built (trash repo): a move renames the item and writes its record first;
  a rename that fails takes the record back. Put Back never replaces: a file
  at the recorded path gives `AlreadyExists` and nothing changes. The record
  goes after the item is back, and a record whose item is gone is removed at
  the next start. Ids are the first number no item or record has.
- The entitlement is `tessera.trash`. Only programs the system runs hold it, so
  apps cannot reach the service until a grant is made for Inlay with the
  Trash view.
- The Trash's rules are tested in `trash/tests/trash_kik` with `kira test`,
  against the `trash/store` library. The boot check `trash-check` was merged
  into that harness and removed, so the `-test` boot no longer runs it.

## 1. Manage files in Inlay

Inlay has a place for the person's documents, a sidebar for favourite folders
and mounted volumes, and navigation back, forward and to the parent. List and
icon views support selection, sorting and file information.

New Folder, Rename, Duplicate, Copy, Move and Move to Trash operate on the
selection. Copy and move show progress and can be cancelled. A name collision
offers Replace, Keep Both or Skip; replacing a folder must explain whether its
contents are merged or replaced before changing them. A failed or cancelled
cross-volume move keeps the source until its copy has completed successfully.

Trash records an item's original location and supports Put Back. Empty Trash
asks before permanently deleting anything. A volume that cannot support Trash
offers an explicit permanent-delete action. A read-only volume says why an
operation is unavailable.

Ends when a person can organise a folder and recover something deleted by
mistake, including after a reboot.

- [ ] Create a folder, copy a file into it, rename it and find the same contents
      after rebooting.
- [ ] Move a file to Trash, reboot, then Put Back restores its contents to its
      original location; a collision asks what to do.
- [ ] Copy a directory to another writable volume, cancel midway, and see which
      items completed. A cancelled move retains every source not fully copied.
- [ ] Unplugging a destination during a copy produces an actionable failure and
      keeps the source. Read-only media cannot be offered as writable targets.

Status (2026-10-26): Inlay lists Documents (`/Documents`, bound from the data
volume by PID 1), every volume that is not an opened disk image, and the
Trash. In a folder it offers New Folder, Rename, Duplicate, Copy, Cut, Paste,
Move to Trash on the data volume and Delete Immediately elsewhere; a read-only
volume offers no changes. Copy and move step one entry per frame with
progress and Cancel, ask Replace, Keep Both or Skip, and keep every source a
failed or cancelled move had not finished copying. The rules are the
`FileOperations` library in `inlay/operations`, tested on the host by
`inlay/tests/operations_kik` (12 passed). The Trash service gained List and
Empty for Inlay's Trash view. Not yet shown on a boot.

### Host file-operation safety update (2026-10-31)

The `FileOperations` layer now rejects symbolic-link parent traversal in
recursive delete, copy, move, rename and folder creation. It treats dangling
links as occupied names, and failed Duplicate operations clean up partial
copies. Replace now moves the existing target aside on its destination volume
until the incoming transfer completes; if copying fails, the previous item is
restored. Successful replacements remove the old entry, and failed restoration
leaves the recovery-named entry rather than discarding its bytes. Host tests
cover these cases, including folder contents with unsupported links. This is
a **best-effort transaction**: it does not yet use fd-relative filesystem
operations or a kernel no-replace rename, and it cannot guarantee correctness
if another process concurrently swaps or creates path entries. The real boot,
removable-volume and user-interface checkpoints above remain open.

### Open With identity and preference model (2026-10-31)

`AppRegistry.DocumentAssociations` now routes conventional filename extensions
to a currently accepted publisher-bound application identity. User-selected
defaults survive restart in a strict, bounded preference file and fail closed
on damaged or linked metadata. An uninstalled default remains an unavailable
identity, not a request to open a similarly named app from another publisher.
The model does not execute an application, establish a trusted document handle,
or install a file association in the running shell. PID 1 and Inlay must still
wire these choices through the verified launcher and document access grants.
Host tests cover identity isolation, duplicate extensions, corruption,
persistence, and symlinked preference paths.

## 2. Open and save documents

Applications declare the document types they can open. Inlay opens a document
with its chosen default application; Open With lets the person choose another
and change the default. Unknown types can still be inspected or offered to an
application without being treated as executable programs.

Open and Save dialogs share Inlay's navigation. An application receives access
to the selected document, with the rights the operation needs. A dialog's
Cancel gives it no new access. This uses the trusted picker and grant boundary
in [16](16-libtessera.md) §14, which is still to be implemented.

A document window shows its name and whether it has unsaved changes. Closing
such a window offers Save, Discard or Cancel. Save As chooses a new destination;
a write failure leaves the edited document available to save elsewhere.

Ends when Notes can edit an ordinary document outside its private data folder.

- [ ] Open a text file from Inlay in Notes, edit it, save it and reopen the
      saved contents after a reboot.
- [ ] Save As creates a separate document; cancelling an overwrite or closing
      dialog preserves the existing file and the unsaved edits.
- [ ] A confined application can use the selected document but cannot read a
      neighbouring document that was not granted to it. Revocation prevents a
      later reopen through the saved grant.
- [ ] Open With chooses between two registered applications and remembers the
      selected default across a reboot.

### Read-only document discovery foundation (2026-10-31)

The host `FileOperations` library now includes `searchDocumentsByName` with
bounded folder depth, result count, total entries examined, case-insensitive
filename matching and deterministic traversal; it refuses linked roots and
does not follow links to neighbouring folders. `previewDocument` reads at most
64 KiB, returns bounded printable UTF-8 text or a candidate PNG/JPEG/GIF/WebP
signature, and never executes content or decodes arbitrary image pixels.
`RecentDocuments` records successful-open events in a versioned UTF-8-safe
cache, keeps missing removable documents as unavailable, refuses unsafe path
entries, and supports an explicit Forget operation. The read-only APIs and
persistence have host regressions. They do not constitute the Inlay search,
preview or Recents UI, an image decoder, access-grant enforcement or a boot
acceptance run; those original checkpoints remain open.

## 3. Find and inspect documents

Inlay searches names within the current folder or the person's document
locations. Results show their location and can be revealed in their folder.
Recent Documents records documents opened successfully and removes unavailable
entries cleanly. A preview shows text and supported images without opening an
editor; unsupported formats still show file information.

Search and previews respect the same access boundaries as opening files.
Search indexes and preview thumbnails are disposable caches ([05](05-storage-and-state.md)).
Content search can follow once name search works.

- [ ] Search finds a renamed file, stops listing a deleted file, and does not
      return another application's private data.
- [ ] Preview a text file and an image, then use Open to reach the selected
      application. A malformed file reports a preview failure without ending Inlay.
- [ ] A recent document reopens after a reboot; one on an absent removable
      volume is shown as unavailable and can be removed from the list.

On case-insensitive volumes, copy and transfer containment checks now compare
folded paths conservatively. A same-folder transfer using a differently cased
alias duplicates the item rather than offering to replace its own source.
Hostname-independent symlink and casing tests remain part of the host harness;
OS-backed no-replace rename and concurrent mutation safety are still open.
