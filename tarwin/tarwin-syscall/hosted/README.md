# Hosted gate protocol, version 1

The gate request is a simple Mach message (`GateRequest.messageID`). Its
destination is the task's gate send right (`COPY_SEND`). It carries a
`MAKE_SEND_ONCE` reply right in the header. The gate sends and receives with
one `mach_msg` call. A reply is a simple Mach message (`GateReply.messageID`)
sent with `MOVE_SEND_ONCE`; it carries no further reply right. The bytes below
start after the Mach header and exclude the receive trailer.

| Payload | Little-endian fields in order |
| --- | --- |
| Request (88 bytes) | version (u32), reserved zero (u32), Tarwin thread ID (u64), call number (x16, u64), x0 through x7 (u64 each) |
| Reply (40 bytes) | version (u32), reserved zero (u32), status (x0, u64), detail (x1, u64), first value (x2, u64), second value (x3, u64) |

The gate receive right identifies the task. The thread ID is an untrusted
selector within that task; it is not an authority or proof of which instructions
the task ran. The receiver resolves it against the kernel's thread state and
uses only the selected thread's registered, bounded shared argument mapping for
copying arguments beyond the eight inline registers. The pointer in the last
inline argument for such a call is interpreted under Tarwin §10.2–10.3; it is
never dereferenced as a host pointer. No out-of-line descriptors are used in
this version.

Dispatch uses the train's existing `TarwinABI` register types and syscall
numbers. Immediate replies consume the send-once right at dispatch; blocking
calls move ownership of the right into the kernel's wait state, releasing the
worker to handle another request. Completion consumes the right once;
cancellation or task teardown releases it if no reply can be sent.

The wire format does not carry a claimed program counter. A value supplied by
the caller would not establish trusted call origin.

`TarwinKernelGate` binds a gate receive port and audited PID to one kernel
process. A verified trap handler must authorize the captured call registers
before the matching Mach request can enter `TarwindKernel`. The authorization
is single-use. The event loop calls `completeReady()` to consume ready kernel
continuations and reply without making a gate worker wait.
