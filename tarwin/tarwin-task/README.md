# Hosted task command protocol, version 1

`TarwinTaskProtocol` is shared between the hosted kernel and the task host.
Each request is one Mach message (`TaskCommand.messageID`) with a
`COPY_SEND` destination on the command port and a `MAKE_SEND_ONCE` reply
right in the header. `map` and staged live-memory requests are complex: a Mach message body with one
`MACH_MSG_PORT_DESCRIPTOR` (`COPY_SEND` memory-entry right) precedes its
payload. The payload starts after that descriptor, or immediately after the
Mach header for simple messages. The receive trailer is not part of it.

All payloads start with version (u32, 1) and opcode (u32). All fields are
little-endian; there is no implicit padding. Addresses, lengths, offsets,
Tarwin thread IDs and register values are u64 unless otherwise noted.

| Opcode | Command | Fields after the common header |
| --- | --- | --- |
| 1 | Map | address, length, memory-entry offset, Mach protection (u32), copy (u32: 0 shared, 1 copy-on-write) |
| 2 | Protect | address, length, Mach protection (u32), reserved zero (u32) |
| 3 | Unmap | address, length |
| 4 | Create thread, suspended | thread ID, entry PC, initial x0 argument, stack pointer, static TLS/TCB address |
| 5 | Set thread state | thread ID, x0 through x30, SP, PC, CPSR (u32), reserved zero (u32) |
| 6 | Suspend thread | thread ID |
| 7 | Resume thread | thread ID |
| 8 | Terminate | none |
| 9 | Snapshot | address, size |
| 10 | Thread identity | thread ID |
| 11 | Read memory | address, size |
| 12 | Write memory | address, size, inline bytes (if not staged) |

The TLS field is a Tarwin virtual address, not a host register selector.
On macOS 26.6.2, the task-side probe could write `TPIDR_EL0` but did not
retain the value across a blocking `nanosleep`. Hosted TLS must use the
gate-page TCB access path from TarwinHosted §5.3, not `TPIDR_EL0`.
The thread ID is assigned by the hosted kernel, not a Mach port name.
The hosted kernel maintains the authoritative address map and thread state;
successful status from the task is not security evidence.

Every request has one reply (`TaskCommandReply.messageID`), sent with
`MOVE_SEND_ONCE` and no further reply right. Its first eight payload bytes are
version (u32) followed by the Mach return status (i32; zero means success).
Only a successful `snapshot` has a complex reply: one port descriptor carries
the copy-on-write memory-entry send right. Pass `reply.memoryEntry` to
`map(copy: true)` with offset zero, then deallocate the owned send right.
Snapshot ranges must be nonempty page-aligned guest mappings with maximum
protection allowing read and write, and cannot include the gate page. Current
protection may be more restrictive, including `PROT_NONE`. The task can
snapshot through a temporary COW alias without changing the original mapping's
protection. Suspend guest writers before snapshotting multiple ranges when
they must describe the same point in time.
A successful `threadIdentity` appends the kernel's `THREAD_IDENTIFIER_INFO`
thread ID (u64); failures have only the status payload. Pass the logical
Tarwin thread ID to `SpawnedTask.threadIdentity(id:)` after creating the
thread and before its first resume.
`terminate` acknowledges before exiting; process exit is observed separately.

Live-memory transfers accept byte-aligned ranges of 1–1,048,576 bytes below
the gate page in the task window. They follow the task map's current
protections and write through to its live mapping, including private COW
pages. Unmapped or inaccessible ranges return a Mach error. A failed write
is not a rollback guarantee; the caller must resolve faults and pin the
whole range before the command.

Up to 256 bytes travel inline. A successful inline read appends a u64 byte
count and the bytes to the reply; `TaskCommandReply.data` exposes them.
Inline write requests carry the bytes after the size. Inline bytes are
zero-padded to a multiple of four. Larger reads and writes carry one
`COPY_SEND` staging memory-entry descriptor in the request, at offset zero.
The task writes the staged read result into that entry or reads the staged
write source from it; both replies contain only the status. Use
`SpawnedTask.readMemory(address:into:)` and
`SpawnedTask.writeMemory(address:data:)` to choose the transport and
manage staging automatically.

The Swift codecs take exact payload slices and do not allocate or require
aligned pointers. Mach header, descriptor and trailer validation is the
transport's responsibility.

## Check-in

`TaskSpawner.spawn` starts the task with no environment or inherited
descriptors and a private bootstrap port. The task sends one complex message
with ID `TaskCheckIn.messageID` on that port using `COPY_SEND`. The body
contains two port descriptors, in order:

1. Command port `MAKE_SEND`: the task retains its receive right.
2. Gate port `MOVE_RECEIVE`: the task retains only a send right.

The eight payload bytes are version (u32) and reserved zero (u32). There
is no reply right. The spawner accepts this message only from its spawned
PID, using the Mach audit trailer. It owns both returned rights until the
`SpawnedTask` is released. The hosted kernel separately owns process exit
observation and reaping.

In the child, read `TASK_BOOTSTRAP_PORT` with `task_get_special_port` and pass
that send right to `TaskCheckIn.send(bootstrap:)`. Do not look up a launchd
service: there is no service name, environment variable, or extra argument.
After check-in, clear the bootstrap special port and deallocate the retrieved
send right; serve commands on `commandReceive` and send gate calls on
`gateSend`. See [the example child](Tests/TaskCheckInExample/main.swift).
The spawner discards unrelated bootstrap messages from the child (which system
libraries can send before `main`) without restarting the check-in timeout.

`tarwin-task` reserves the 64 GiB `TaskWindow` before checking in. Map,
protect and unmap operate only in that window; unmap restores the address
reservation. The main command thread clears its bootstrap port and installs
a deny-by-default profile before processing commands. All Mach rights needed
by the guest are transferred, not looked up. The optional spawn exception
port uses the same exception mask and message format as `HostExceptionPort`.
