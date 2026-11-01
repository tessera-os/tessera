# 26.10.4

**Project:** libtessera  
**Release week:** 2026-10-26 – 2026-11-01

## Highlights

Made libtessera’s native Linux process, channel and memory interfaces explicit about unchecked operations.

## Changed

- Scoped raw-pointer and native-state operations in Linux backend process/thread, debug, memory mapping, sampling, and channel paths.

## Breaking changes

- Callers crossing unchecked native memory boundaries must use Kira unsafe contexts or safe validated wrappers.
