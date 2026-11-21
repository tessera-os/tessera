# Hosted layer zero

Regular Swift 6 for Apple silicon macOS, exposing `TarwinArchHosted` without
making the other Tarwin layers import Darwin. The tools-6.0 manifest uses
macOS 15 (its available SDK spelling); hosted Tessera deployment remains
macOS 26 per TarwinHosted.md. No task ports are acquired from other processes.

`HostPort` adopts exactly one right reference. Borrowed receive rights and
file descriptors must remain valid until their event registrations are
cancelled; registering a receive right reserves its port-set membership.
Readiness never consumes a Mach message or bytes from an fd. Tokens are
queue-local, cancellation is idempotent, and concurrent waiters may split
events between themselves. Timers take absolute nanoseconds in
`HostClock.absoluteNanos()`'s epoch (not continuous time). Repeating timers
remain anchored to the first deadline and are rearmed with absolute Mach
deadlines on delivery. Missed intervals are counted in `data`, without drift.

Workers set a background pthread QoS baseline and use owned pthread QoS
overrides for remote class changes, releasing overrides on change and exit.
Initial policy is applied before the body runs. Failed time constraints
throw rather than silently claiming realtime service. `waitUntilFinished()`
must not be called on the worker itself. Memory-pressure callbacks run on a
private Dispatch queue; cancellation does not interrupt a callback in flight.

Exceptions use `EXCEPTION_DEFAULT | MACH_EXCEPTION_CODES`, retrieving
`ARM_THREAD_STATE64` from the supplied faulting thread right. This avoids
depending on protected-identity exception APIs for this stage. Sinks run on
the receive worker; they must not wait for the faulting thread. Resume edits
PC, SP and x0–x28 and preserves the remaining register state. Termination
kills the faulting task. The installer owns saving/restoring any previous
exception ports and must uninstall before releasing the service. Installing
on a task is intended for the cooperating task host's own task port.

The C bridge supplies the MIG-checked exception server and pthread/Mach
interfaces that are awkward to express through Swift's imported unions.
Regenerate its checked-in server with the macOS SDK:

```sh
cd Sources/CHostDarwin
xcrun mig -arch arm64 -isysroot "$(xcrun --show-sdk-path)" \
  -header /dev/null -user /dev/null -sheader hosted_excServer.h \
  -server hosted_excServer.c HostedException.defs
```

Run `swift build` and `swift test`. The exception tests run an isolated helper
process with a thread-level exception port, deliberately fault at address
0x1000, check decoded registers/address, then test both resumption and task
termination. No fault is deliberately raised in the XCTest process.
