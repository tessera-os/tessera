# Hosted TRFS mount and shared folders (H4)

The hosted mount for Tessera.app (TarwinHosted.md HS-011, piece H4). The
Tarwin I/O piece owns the rest of `trfs/`; this package only uses TRFS's
public API.

- `TRFSHosted`: `HostedTrfsDisk.openData` mounts the data volume from
  `<Disks>/<name>.trfs`. A missing image is created sparse and formatted
  with `formatBlank()`; an existing image is only mounted and never
  reformatted, so a damaged disk fails instead of losing data.
  `openSystem` mounts the signed system volume read-only through
  `mountSystem(bootSetRoot:measure:)` and fails closed. Each live volume
  has its own 4096-byte scratch page, and `withVolume` serializes access.
- `TarwinHostFolder`: a Mac folder the user picked, served as an A.5
  (`TarwinFsWire`) volume. `HostFolderGrant` keeps the picker's
  security-scoped bookmark; `HostFolderVolume` walks every path from the
  granted folder one component at a time with `O_NOFOLLOW`, hides symbolic
  links and refuses `.`, `..` and `/` in names, so requests never leave the
  folder. Read-only grants refuse every change. `HostFolderServer` is the
  ring loop, with the same contract as `ReadOnlyServer`.

Beyond the read-only request set: `create` takes the name as input and the
kind in `offset` (1 file, 2 directory) and returns the node; `remove` takes
the name; `rename` takes `old 0x00 new` from directory `node` to directory
`other`; `setAttributes` sets the size to `offset`; `statFileSystem` returns
total and free bytes. Run `swift test` here.
