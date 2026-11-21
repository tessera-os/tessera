# Tessera for macOS

Requires Apple silicon, macOS 26 and Swift 6.3. Regular Swift throughout.

Build: `scripts/build-app.sh`. Open: `open build/Tessera.app`.
Test: `scripts/test.sh` (unit tests, signed bundle, headless XPC boot).
For a separate disk: `build/Tessera.app/Contents/MacOS/Tessera --disk /path/to/directory`.
The default sparse disk is 64 GiB logical under `~/Library/Application Support/Tessera/Disks/`.

TarwindKernel is the default kernel; --stub-kernel selects the original stub.
The real kernel reports time, objects, syscalls, scheduler, ready and calls ready().
The desktop is still our IOSurface/Metal preview, not running Tessera userland or
a TRFS filesystem. It exercises XPC, disk block I/O and input at 30 fps.
Boot errors fall back to StubKernel and remain visible on the console overlay.
The system image remains a placeholder. The bundle script builds and signs H2's
real sandboxed tarwin-task executable from ../../tarwin/tarwin-task. At ready the
service launches it, validates check-in, sends a protect command and serves its
gate port. No image is loaded into that process yet. The Swift gate-demo child
is now the test-only tessera-test-task target and is not copied into the bundle.

H6's mac-hid, mac-audio and mac-power packages are relative SwiftPM dependencies.
Raw focused-window NSEvents go through HIDEventTranslator; focus loss emits releases.
TWHD frames cross the existing NSXPC connection in a `tw.frame` Data dictionary.
The service registers MacHIDDeviceProvider, MacAudioDeviceProvider and
MacPowerDeviceProvider in HostDeviceRegistry and delivers inbound frames through
their Mach inboxes. Returned frames are demultiplexed to the app-side hosts.
MacPowerHost observes real host state; MacAudioHost runs its control/timing layer
but endpoints remain idle: PCM shared-memory ring negotiation is not implemented.
No microphone is opened and no audio playback is claimed.

The stub desktop consumes HID keyboard reports with a minimal US letters/digits
mapping, not a text-input service. Pointer motion still uses the existing stub
HostEvent path as well as reaching H6. No H5 graphics drivers are integrated yet.
The cross-process check-in/gate test uses H2's fix for unrelated bootstrap traffic.
Its test child checks in before clearing and releasing the bootstrap port.

TarwindKernelAdapter maps lifecycle callbacks to the host on the main queue.
H6 providers and the preview display provider are registered before boot.
H1 retains the paths but does not load images yet; the service separately launches
the sandboxed task host. Its gate handlers remain diagnostic stubs, not H1's
KernelGate: task-side pinned memory and trap validation still need integration.
There is no LibTessera app, H5 compositor or loaded guest image in this bundle.
The bundle test requires real ready and all five stages; fallback is not a pass.
KernelConfig carries diskPath, systemImagePath, panicRecordPath and taskExecutablePath;
KernelHost has the same four callbacks as TarwindHost. Register HostDevices display/HID
providers in TarwinArchHosted's HostDeviceRegistry before boot. No dependency on those
unlanded packages is required here. The real kernel owns input device delivery; the stub
uses a separate HIDProvider. XPC control stays independent of the kernel implementation.

The app shows the console during boot and reconnects after XPC interruption, preserving
the panic text in its console overlay before restarting. Start/Shut Down/Restart/Recovery
are in the app menu. Recovery currently reboots the stub. Disk header version 1 is a
4096-byte block containing TRFSDISK, version, UUID and Unix creation time on separate
lines; the boot counter occupies eight little-endian bytes at offset 4096.
