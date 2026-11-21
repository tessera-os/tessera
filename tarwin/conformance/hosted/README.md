# HOSTED composition checks

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

The injection test exercises the crash transition, not a real Mach fault.
Real exception decoding/resume/termination is tested by `tarwin-arch-hosted`.
These tests do not run task images, storage, graphics or a native boot, and do
not replace the native suites or performance gates.
