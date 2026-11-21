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
At sequence 4153, H1's #4340 mounts block/TRFS, has host-side network and
shared-folder APIs, but lacks authorized signed app launch, gate file/network
dispatch and exit. `hosted-io-e2e run` returns unavailable (69); never treat
a successful preflight, unit test, or an SDK source file as guest I/O.

## Signed application trial

Use the real Tarwin-target LibTessera image and H1's verified launch path;
do not relink as Mach-O, use a test kernel or pass an always-allow verifier.
The planned fixture ID is `org.tessera.conformance.hosted-io-client`. The
loader must bind it and the signed outbound `tessera.network.client`
entitlement to this particular launch. Grant read, write and create-child
rights on the disposable data root only, plus the per-app network policy. No device, system volume write,
ambient file descriptor or unscoped network grant.

1. Create a fresh `RunProof`. It reserves both listeners on IPv4 loopback
   before launch, generates a private 32-byte nonce and names a new data disk
   inside a private directory. Busy ports fail the run; there is no fallback.
2. Boot tarwind with that disk and the authenticated system image, then launch
   the signed test application through H1/H2. After the main thread resumes,
   call `exchangeWhileRunning()`. The app connects to 127.0.0.1:43871, reads
   the nonce, writes and syncs `hosted-io-proof`, closes and reopens the file,
   reads exactly 32 bytes and EOF, and sends the reread bytes back. The runner
   acts only as the peer, never as the client or the file writer.
3. The signed app must also attempt TCP 127.0.0.1:43872 and get the kernel's
   access-denied status. Socket refusal, timeout or rejection before the gate
   is not the intended result. The runner keeps a real listener on this port
   throughout so an unintended connection cannot pass as a refusal.
4. Require normal zero exit within a bounded time; any fault, killed task,
   timeout, nonzero exit or unverified identity fails. Shut tarwind down before
   `verifyAfterShutdown(normalExit:)`. It checks the sentinel has no queued connection
   and takes a read-only lock on the existing data image, mounts TRFS, checks
   exact filename, length and authenticated bytes. It never formats or repairs
   the disk. An empty listener alone cannot establish which guest error occurred.

Prerequisites not present on this pin: H1's hosted-only debug app signer and
verified launch/exit, H1's guest-callable file/node/network providers with
signed identity and explicit denial, and H7's Tarwin-target LibTessera build.
H1 owns the daemon; H2 owns task host and gate; H3 owns verified image placement.
A shared-folder guest test additionally needs a guest-visible grant and SDK
route. This runner is headless hosted evidence, not the Tessera.app XPC/UI
path, a native boot, physical hardware, or a performance gate.
