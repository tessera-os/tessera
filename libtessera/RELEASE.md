# 26.11.1

**Project:** libtessera  
**Release week:** 2026-11-02 – 2026-11-08

## Highlights

Expanded Linux system interfaces for partitions, remote processors, kernel logging, and developer touch dead zones.

## Added

- `launchInfoCreateURL` and `processLaunchURL` for bounded, typed URL launch
  metadata. The URL is encoded in the LaunchInfo URL field, not argv; the
  receiver validates size, optional tag and string bounds before reading.
- `launchDocumentEntry` and `processLaunchDocument` for a document File grant
  in a confined child's startup message. The startup validator accepts only
  one explicitly narrowed File grant with read (and optionally write) rights;
  directories, unconfined launches and unbounded rights are rejected.
- The common LaunchInfo argument reader now bounds startup memory, argument
  count and per-argument length, matching the URL launch writer's limits.
- `WorkspaceRequest.OpenDocument` uses opcode 12 with a separate File handle
  (never the document's pathname). The request's mode selects read-only or
  explicitly editable access; the newly launched confined recipient strips
  the bootstrap Transfer bit from the received File handle.
- `nodeSnapshot` exposes typed Node identity, volume, size and modification
  metadata for comparing an opened File against its selected Node without
  decoding raw binary structs or looking up its pathname again.
- `linuxDeviceIdFromVolumeId` converts statx major/minor packing into the
  device number returned by Foundation's Linux file status, allowing Inlay
  to compare both device and inode against the original selection.
- `fileSnapshotMatches` compares an open File's identity, volume, size and
  modification timestamp for optimistic, non-atomic editor conflict checks.
- PID 1 can now inspect an opened File's node kind and uses
  `eligibleNotesDocument` to reject special nodes, files over 1 MiB, and
  incompatible read/write modes before launching Notes.
- Moved the document workspace-wire and FileSnapshot tests to the isolated
  `libtessera/tests/document_kik` package; it source-checks without KiraUI.
- Added `ServiceOpcode.DocumentOpened` (13) and strict reply validation.
  Explicit PID 1 acknowledgement is required to record a successful document
  launch; peer closure or a malformed header cannot impersonate success.
- `volumePartitionBytes` and `volumePartitionLabelled` to inspect partition size and find a GPT-named partition.
- `machineStartRemoteProcessors` / `RemoteProcessorStart` for starting supported offline remote processors after the system volume is available.
- `standardStreamsToKernelLog` and `kernelLogText` for writing to and reading from the kernel log.
- Developer dead-zone settings and live-area calculations for avoiding a damaged screen edge.

## Changed

- Expanded explicit unsafe scopes across Linux process, memory, channels, debugging, and other native implementation paths.

## Known limitations

- Typed URL and document startup metadata are available. The explicit
  Inlay → PID 1 → Notes document-open path is now connected in source, but the
  generic signed-registry dispatcher, document picker for other apps, and
  live-app RIDL activation are not yet integrated or guest-boot verified.
- Hardware-specific remote-processor startup and partition behavior have not been validated across device profiles for these notes.
