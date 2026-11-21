# HOSTED composition checks

Canonical package path: `tarwin/conformance/tarwind-hosted`. The distinct folder
name avoids SwiftPM's root identity collision with `tarwin-syscall/hosted`.

Run `swift build` and `swift test` here on Apple silicon macOS 26 with the
neighboring `tessera/build/tarwin-hosted` package present. For separate Cairn
mounts, set `TARWIN_HOSTED_ROOT` to that package and `TARWIN_SOURCE_ROOT` to the
Tarwin tree. Both defaults use the canonical repository-relative layout.

The parent conformance package is a lab controller/evidence checker, not a
reusable kernel test case list. These hosted cases boot the real composition
and use its dispatcher and providers, without claiming native acceptance.

Corresponding **Tarwin.md section 34.1** suites:

| Hosted cases | Suite |
| --- | --- |
| Object creation, attenuated rights, close, namespace isolation, signals, blocking waits, timeout/cancel, channel bytes and moved handles, peer closure | Objects and IPC |
| ABI results, unknown calls and processes, malformed arguments, invalid registered-memory ranges, monotonic Time.read | System calls |
| Crash registry removal, cancellation of the faulting process's calls, survival of another process, no kernel panic | Objects and IPC; System calls |
| Scheduling-class mapping tests in the composition package | Scheduling (mapping only, not fairness/admission evidence) |
| TRFS write/shutdown/remount/read, damaged disk refusal, verified read-only system mount and measurement refusal | File systems |
| Shared-folder A.5 ring lookup/read, read-only refusal, descriptor ownership and unshare revocation | File systems |
| Loopback TCP connect/echo, event queue completing a blocked Object.wait, endpoint close | Networking; Objects and IPC |
| Registered host-provider slot open and a usable Mach send right | Devices (hosted transport only) |

The injection test exercises the crash transition; the composition package also
runs a real Mach fault in an isolated helper. Its pager maps the faulting page
and retries the original load, while missing/declining/throwing/terminating
pagers take the fatal path. H6's inbox ports are tested without starting UI,
audio hardware or power observers. File operations use the mounted TRFS and
HostFolderServer APIs, not a filesystem syscall bank (none is wired to this gate).
These tests do not run task images, graphics or a native boot and do not replace
the native suites or performance gates.
