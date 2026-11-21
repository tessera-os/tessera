# Hosted I/O acceptance: preflight and witnesses

Run `sh ./check.sh` in this directory on Apple Silicon macOS 26 with Swift 6.2+
and the neighboring Tarwin packages present. It builds **the real sandboxed
tarwin-task executable**, boots TarwindKernel over a fresh disposable data disk
and a repository-generated read-only TRFS system fixture, checks its known
metadata root, receives the child's Mach check-in, terminates and reaps it.
It repeats with an absent image and with both anchors damaged; neither may pass.
The fixture pin is only for this preflight; it does not authorize a signed app.

The separate unit tests exercise the proof code using a local TCP test peer
and an on-disk TRFS test volume. **No test client here is a guest app.**
`hosted-io-e2e run` returns unavailable (69) until verified launch, guest
file/network dispatch and exit are wired. A successful preflight, signer
test or SDK source file is not guest I/O.

## Signed application trial

Use the real Tarwin-target LibTessera image and H1's verified launch path;
do not relink as Mach-O, use a test kernel or pass an always-allow verifier.
Build the real LibTessera client as a finalized `aarch64.base` ET_DYN with
compiler note 6 and the [wire format](../../tarwin-loader/IMAGE-WIRE.md)'s
note 7 **app/executable** bytes `00 00`. Its entry is
`_tarwin_process_start` with one bootstrap-channel handle. From this directory:

```sh
swift run --package-path ../../../tessera/build/tarwin-hosted tarwin-hosted-sign \
  --app-id org.tessera.conformance.hosted-io-client \
  --entitlement tessera.network.client input.elf signed.elf
```

Require a signer that **preserves** the app role and a verifier that rejects
system/executable (`01 00`). Do not use the initial signer at sequence 4444:
both signer and verifier used the system role there. Never patch note 7 or
manufacture a finalizer note to make the test pass. The signer's synthetic
admission fixture is not a runnable client.

Require the hosted debug-app trust policy to verify the app ID in the TSG1
identity claim and the exact entitlement above in signed note 3. The launch
must bind that identity and policy to this process. Grant read, write and
create-child rights on the disposable data root only. No device, system
volume write, ambient file descriptor or unscoped network grant.

1. Create a fresh `RunProof`. It reserves both listeners on IPv4 loopback
   before launch, generates a private 32-byte nonce and names a new data disk
   inside a private directory. Busy ports fail the run; there is no fallback.
2. Boot tarwind with that disk and the authenticated system image, then launch
   the signed test application through H1/H2 with `RunProof.launchGrants()`.
   After the main thread resumes,
   call `exchangeWhileRunning()`. The app connects to 127.0.0.1:43871, reads
   the nonce, writes and syncs `hosted-io-proof`, closes and reopens the file,
   reads exactly 32 bytes and EOF, and sends the reread bytes back. The runner
   acts only as the peer, never as the client or the file writer.
3. The signed app submits TCP connect to 127.0.0.1:43872 with key 30. Require
   one asynchronous Net completion (kind 7), key 30, with AccessDenied/Network
   (`0x0000000600000004`). A failed submission or wait, socket refusal,
   timeout or SDK-only denial fails. Require the same run's kernel decision
   for this process, verified app, outbound TCP destination and policy denial,
   with `socketCreated == false`; the denied listener must remain untouched.
4. Require normal zero exit within a bounded time; any fault, killed task,
   timeout, nonzero exit or unverified identity fails. Call
   `captureSocketDecisions(kernel:process:)` for that launch before shutdown.
   It requires exactly the allowed socket and the policy denial in order.
   At sequence 4485 the journal has no direction or terminal snapshot; a live
   sample cannot prove the final outbound decision. Keep guest acceptance
   unavailable until the terminal outbound records can be checked.
   Shut tarwind down before
   `verifyAfterShutdown(normalExit:)`. It checks the sentinel has no queued connection
   and takes a read-only lock on the existing data image, mounts TRFS, checks
   exact filename, length and authenticated bytes. It never formats or repairs
   the disk. An empty listener alone cannot establish which guest error occurred.

Beyond correct hosted debug-app signing, the run needs H1's verified launch
and exit, guest-callable file/node/network providers and guest memory, and
H7's Tarwin-target LibTessera build.
H1 owns the daemon; H2 owns task host and gate; H3 owns verified image placement.
A shared-folder guest test additionally needs a guest-visible grant and SDK
route. This runner is headless hosted evidence, not the Tessera.app XPC/UI
path, a native boot, physical hardware, or a performance gate.
