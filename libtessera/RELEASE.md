# 26.10.4

**Project:** libtessera  
**Release week:** 2026-10-26 – 2026-11-01

## Highlights

Made libtessera’s native Linux process, channel and memory interfaces explicit about unchecked operations.

## Changed

- Added `volumePartitionBytes` and `volumePartitionLabelled`: a partition's size, and the partition with a given GPT name on any disk.
- Added `machineStartRemoteProcessors` and `RemoteProcessorStart`: starts the remote processors the kernel holds offline, such as a phone's ADSP, once the system volume with their firmware is the root.
- Added `standardStreamsToKernelLog`: standard output and error point at the kernel's log, so a program's console lines are kept with the kernel's own.
- Added `kernelLogText`: the newest text of the kernel's log, read without taking it out, for system services that show the machine's log.
- Scoped raw-pointer and native-state operations in Linux backend process/thread, debug, memory mapping, sampling, and channel paths.

## Breaking changes

- Callers crossing unchecked native memory boundaries must use Kira unsafe contexts or safe validated wrappers.
