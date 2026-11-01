# trash

The Tessera Trash service (roadmap/19, decisions in its Decisions section).

It listens as `tessera.trash`, and serves one request per connection. A move
renames an item on the data volume into `/data/Trash/items` and writes its
record into `/data/Trash/records`, which names the item's original path. The
record goes first; if the rename fails, the record is taken back. Items on
another volume are refused `Unsupported`, and paths outside `/data`, under
`/data/system` or under the Trash are refused.

Put Back (`trashPutBack`) takes an id the move answered. It renames the item
back to the path its record names, and never replaces anything: when a file is
at that path, the answer is `AlreadyExists` and nothing changes. The record is
removed after the item is back. At start, a record whose item is gone is
removed.

LibTessera's `trashMove` and `trashPutBack` call it. Only programs the system
runs hold the `tessera.trash` entitlement. Listing and emptying the Trash are
now implemented. Folder deletion does not follow symbolic links. Moves and
restores reject ambiguous path components, links in parent directories, and
linked Trash metadata directories; this reduces accidental traversal outside
`/data` without claiming full protection against concurrent path-swap races.
The host-testable `TrashRules` package contains the validation and no-follow
folder removal rules. Host tests and an aarch64 Linux-target store check run
without booting the OS.

It is built with the other programs by `tessera/build` and started by init as
`/bin/trash`.

## No-follow metadata hardening (2026-10-31)

Trash ID allocation, orphan-record cleanup and restore collision detection now
use no-follow metadata. Dangling links count as occupied names and cannot cause
an ID to be reused or an existing restore destination to be replaced. Record
files must be regular files, not symlinks to attacker-controlled text. New
item IDs are canonical decimal integers 1 through 999999; ambiguous aliases
such as `001` are refused. Trash folder ancestors are checked for links after
each required parent is created, allowing clean first-boot initialization
without following a linked `/data` or Trash parent.

The host-testable `TrashRules` suite exercises the no-follow and canonical-ID
rules; the Linux-target `TrashStore` package compiles. A full running-system
Trash round trip is still pending a completed Tessera boot. Concurrent path
replacement remains an OS-level race requiring fd-relative operations or
exclusive creation/rename syscalls, not just preflight checks.

## Strict request payload parsing

The service now validates the entire request payload before interpreting a
path or ID. It decodes UTF-8 by the declared message length rather than
C-string termination, rejecting embedded NUL bytes, malformed UTF-8 and
payloads larger than 4096 bytes. Move accepts only valid paths under `/data`;
Put Back accepts only canonical numeric IDs; List and Empty require zero
payload bytes. The host rules tests cover suffix-smuggling and malformed
messages, and the full Trash service passes aarch64 Linux compilation. The
running-system authorization boundary still depends on Tessera's service
entitlement checks and a completed OS boot test.

The request's reserved 32-byte header fields are also checked for the zero
values emitted by LibTessera clients, and unexpected attached IPC handles are
closed and rejected. This prevents noncanonical requests from being accepted
while ignored header arguments go unexamined.

A Trash listing larger than the current 64 KiB IPC reply budget now fails
explicitly with `NoSpace` rather than returning an incomplete list as success.
Pagination remains a later protocol feature. The service does not delete or
truncate the stored items when this happens.

Restore record files now have a fixed 4,144-byte upper bound, checked via
no-follow file metadata before reading and again in the host-testable parser.
This prevents a damaged on-disk record from being loaded or interpreted as an
unbounded restore instruction. Concurrent replacement between metadata and
read still requires fd-relative filesystem operations to close fully.
