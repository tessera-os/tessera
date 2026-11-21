# Tessera for macOS

Requires Apple silicon, macOS 26 and Swift 6.3. Regular Swift throughout.

Build: `scripts/build-app.sh`. Open: `open build/Tessera.app`.
Test: `scripts/test.sh` (unit tests, signed bundle, headless XPC boot).
For a separate disk: `build/Tessera.app/Contents/MacOS/Tessera --disk /path/to/directory`.
The default sparse disk is 64 GiB logical under `~/Library/Application Support/Tessera/Disks/`.

This is a stub kernel desktop, not a running Tessera userland or TRFS filesystem.
It exercises XPC, disk block I/O, input and IOSurface/Metal presentation at 30 fps.
The system image remains a placeholder. The bundle script builds and signs H2's
real sandboxed tarwin-task executable from ../../tarwin/tarwin-task; the stub
does not launch it yet.

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
The previous Foundation-based test child hit H2's rejection of runtime bootstrap
traffic before TaskCheckIn. That experimental launcher is not included here;
launching the bundled sandboxed executable is not wired into the stub yet.

Replace `KernelFactory.make(devices:)` with an adapter for `TarwindKernel.Tarwind.boot`.
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
