# Tessera for macOS

Requires Apple silicon, macOS 26 and Swift 6.3. Regular Swift throughout.

Build: `scripts/build-app.sh`. Open: `open build/Tessera.app`.
Test: `scripts/test.sh` (unit tests, signed bundle, headless XPC boot).
For a separate disk: `build/Tessera.app/Contents/MacOS/Tessera --disk /path/to/directory`.
Tarwind creates and formats its own data disk under `~/Library/Application Support/Tessera/Disks/`.
The app moves an old TRFSDISK v1 file to a unique `.legacy-<UUID>` backup before boot;
it does not format, resize or write the data volume. StubKernel never touches it.

TarwindKernel is the default kernel; --stub-kernel selects the original stub.
The real kernel reports time, objects, syscalls, storage, network, scheduler, ready and calls ready().
The desktop is still our IOSurface/Metal preview, not running Tessera userland or
a guest desktop. Tarwind mounts real TRFS storage; the preview exercises XPC and input at 30 fps.
Boot errors fall back to StubKernel and remain visible on the console overlay.
No system image is bundled until a signed volume is available; the absent path
boots the kernel without a system volume. The bundle script removes only the
old exact placeholder and never suppresses errors for an actual image. It builds and signs H2's
real sandboxed tarwin-task executable from ../../tarwin/tarwin-task. At ready the
service launches it, validates check-in, sends a protect command and serves its
gate port. No image is loaded into that process yet. The Swift gate-demo child
is now the test-only tessera-test-task target and is not copied into the bundle.

H6's mac-hid, mac-audio and mac-power packages are relative SwiftPM dependencies.
Raw focused-window NSEvents go through HIDEventTranslator; focus loss emits releases.
TWHD frames cross the existing NSXPC connection in a `tw.frame` Data dictionary.
The service registers MacHIDDeviceProvider, MacAudioDeviceProvider and
MacPowerDeviceProvider in HostDeviceRegistry. Inbound frames are serialized on
the service main queue and delivered once through their driver channels.
Returned frames are demultiplexed to the app-side hosts. MacPowerHost observes
real host state.
At ready, the service creates playback/capture links and sends their complete libxpc
dictionaries through NSXPCCoder.encodeXPCObject (never Data). The app attaches
them before acknowledging; the service waits for each successful 0x102 status
before advancing open/configure/start. Frame delivery uses the channel callback
once. Restart creates fresh driver mappings and app hosts. Microphone access is
subject to macOS permission and the selected hardware; audio errors are logged.
The audio test transfers links through an anonymous XPC connection and starts
both endpoints with HAL disabled; it does not claim physical audio loopback.

The stub desktop consumes HID keyboard reports with a minimal US letters/digits
mapping, not a text-input service. The report consumer forwards all report kinds,
including gestures and tablets; driver absolute pointer reports drive the cursor.
The view forwards each raw event once without a second legacy pointer path.
Pressure events use a tablet-point adapter because H6's translator does not yet
handle the pressure event type directly. The console cannot intercept clicks or
keyboard focus. No H5 graphics drivers are integrated yet.
The cross-process check-in/gate test uses H2's fix for unrelated bootstrap traffic.
Its test child checks in before clearing and releasing the bootstrap port.

TarwindKernelAdapter maps lifecycle callbacks to the host on the main queue.
H6 providers and the preview display provider are registered before boot.
H1 retains the paths but does not load images yet; the service separately launches
the sandboxed task host. Its gate handlers remain diagnostic stubs, not H1's
KernelGate: task-side pinned memory and trap validation still need integration.
There is no LibTessera app, H5 compositor or loaded guest image in this bundle.
The bundle test requires real ready, all seven stages and a kernel-created disk; fallback is not a pass.
KernelConfig carries diskPath, systemImagePath, panicRecordPath and taskExecutablePath;
KernelHost has the same four callbacks as TarwindHost. Register HostDevices display/HID
providers in TarwinArchHosted's HostDeviceRegistry before boot. No dependency on those
unlanded packages is required here. The real kernel owns input device delivery; the stub
uses a separate HIDProvider. XPC control stays independent of the kernel implementation.

The app shows the console during boot and reconnects after XPC interruption, preserving
the panic text in its console overlay before restarting. Start/Shut Down/Restart/Recovery
are in the app menu. Recovery currently restarts the selected kernel.
