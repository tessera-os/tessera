# Hosted block device (H4)

Tessera.app storage for Tarwin running in macOS user space (TarwinHosted.md
HS-011, section 12 piece H4). Regular Swift, Darwin only.

- `HostedBlockDevice`: one sparse disk image under
  `~/Library/Application Support/Tessera/Disks/`, 4096-byte blocks.
  `create` never reuses a file (O_EXCL), `open` refuses symlinks and sizes
  that are not whole blocks, and an exclusive `flock` keeps a second tarwind
  out. `flush` is `F_FULLFSYNC`; `discard`/`zero` punch holes so the image
  stays sparse.
- `HostedBlockDriver`: serves `TarwinBlockWire` requests (read, write, FUA,
  flush, discard, zero) against the image. tarwind passes the validated
  request, its vector snapshot and a `map` that returns pinned host memory
  for each granted vector; a refused vector fails the request.

The package lives one level down (`hosted/tarwin-block-hosted/`) so its
SwiftPM identity does not clash with the other `hosted/` packages.
Run `swift test` here.
