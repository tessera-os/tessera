# 26.11.1

**Project:** libtessera  
**Release week:** 2026-11-02 – 2026-11-08

## Highlights

Expanded Linux system interfaces for partitions, remote processors, kernel logging, and developer touch dead zones.

## Added

- `volumePartitionBytes` and `volumePartitionLabelled` to inspect partition size and find a GPT-named partition.
- `machineStartRemoteProcessors` / `RemoteProcessorStart` for starting supported offline remote processors after the system volume is available.
- `standardStreamsToKernelLog` and `kernelLogText` for writing to and reading from the kernel log.
- Developer dead-zone settings and live-area calculations for avoiding a damaged screen edge.

## Changed

- Expanded explicit unsafe scopes across Linux process, memory, channels, debugging, and other native implementation paths.

## Known limitations

- Hardware-specific remote-processor startup and partition behavior have not been validated across device profiles for these notes.
